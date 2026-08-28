import {
  applyAssistantPiEventToBlocks,
  assistantPiEventAffectsBlocks,
  asRecord,
  blocksFromMessageContent,
  finalizeRunningToolBlocks,
  messageTextFromBlocks,
  piSessionIdFromEvent,
  upsertTool,
  type AssistantBlock,
  type ChatMessage,
  type QueuedMessage,
  messageText,
  newId,
  nowLabel,
  sessionTitleFromPrompt,
  usageFromEvent,
  visibleUserTextFromPi,
} from "@/features/agent/messages";
import { isAgentEndEvent, piEventIsSuccessfulCompaction } from "@shared/agent/pi-events";
import { traceAgentReasoning } from "@/features/agent/trace-reasoning";
import type { Session, SessionId } from "@/features/agent/runtime/types";

export type SessionStreamContext = {
  // Sync channel for the live assistant id. React state commits lag the event
  // stream within a tick, so when a mid-stream user message opens the next
  // assistant bubble, later events in the same tick must find that id here
  // rather than on the (possibly stale) session snapshot.
  liveAssistantIds: Map<SessionId, string>;
  // Canonical-replay mode (foldSessionEvents). Replay renders one bubble per
  // settled assistant `message` — matching the on-disk log — and never adopts
  // a previous turn's bubble, while the live stream accumulates a whole turn
  // into one bubble. This grouping divergence is deliberate; the flag only
  // switches assistant-bubble targeting and the settled-`message` apply, every
  // other branch is shared.
  replay?: boolean;
};

/**
 * Pure event reducer: fold one pi event — live runtime or canonical log — into
 * a session. The only side channel is `ctx.liveAssistantIds` (see above).
 * Callers dispatch the returned session in a single state commit.
 */
/** Extension-driven prompts (select/confirm/input/editor). Every field is
 *  length-capped because it comes straight off the wire and lands in the DOM. */
function reduceExtensionUiRequestEvent(
  session: Session,
  event: Record<string, unknown>,
): Session | null {
  if (event.type !== "extension_ui_request") return null;
  const method = event.method;
  const known =
    method === "select" || method === "confirm" || method === "input" || method === "editor";
  if (typeof event.requestId !== "string" || typeof event.title !== "string" || !known) return null;
  return {
    ...session,
    extensionUiRequest: {
      requestId: event.requestId,
      method,
      title: event.title.slice(0, 500),
      ...(typeof event.message === "string" ? { message: event.message.slice(0, 4_000) } : {}),
      ...(typeof event.placeholder === "string"
        ? { placeholder: event.placeholder.slice(0, 500) }
        : {}),
      ...(typeof event.prefill === "string" ? { prefill: event.prefill.slice(0, 32_000) } : {}),
      ...(Array.isArray(event.options)
        ? {
            options: event.options
              .filter((option): option is string => typeof option === "string")
              .slice(0, 100)
              .map((option) => option.slice(0, 1_000)),
          }
        : {}),
    },
  };
}

function reduceExecutionLifecycleEvent(
  session: Session,
  ctx: SessionStreamContext,
  event: Record<string, unknown>,
): Session | null {
  if (event.type === "extension_error" && typeof event.message === "string") {
    const message = event.message.slice(0, 4_000);
    const target = resolveAssistantTarget(session, ctx);
    const failed = patchAssistantMessage(
      target.session,
      target.targetId,
      (current) => {
        const blocks = appendFailureBlock(
          finalizeRunningToolBlocks(current.blocks ?? [], "error"),
          message,
        );
        return { ...current, blocks, text: messageTextFromBlocks(blocks) };
      },
      ctx.replay,
    );
    ctx.liveAssistantIds.delete(session.id);
    return { ...failed, activeAssistantId: undefined, error: message };
  }
  if (
    (event.type !== "turn_retry" && event.type !== "turn_waiting") ||
    typeof event.message !== "string"
  ) {
    return null;
  }
  const target = resolveAssistantTarget(session, ctx);
  return patchAssistantMessage(
    target.session,
    target.targetId,
    (current) => {
      const message = event.message as string;
      const detail =
        event.type === "turn_waiting" && typeof event.pending === "number"
          ? `${message} (${event.pending})`
          : message;
      if (current.blocks?.some((block) => block.kind === "event" && block.text === detail)) {
        return current;
      }
      const blocks = [
        ...(current.blocks ?? []),
        { kind: "event" as const, id: newId("lifecycle"), text: detail },
      ];
      return { ...current, blocks, text: messageTextFromBlocks(blocks) };
    },
    ctx.replay,
  );
}

export function reduceSessionEvent(
  session: Session,
  ctx: SessionStreamContext,
  event: Record<string, unknown>,
): Session {
  const afterExtensionUi = reduceExtensionUiRequestEvent(session, event);
  if (afterExtensionUi) return afterExtensionUi;

  if (event.type === "notice" && event.level === "error" && typeof event.message === "string") {
    return { ...session, error: event.message.slice(0, 4_000) };
  }

  const afterLifecycle = reduceExecutionLifecycleEvent(session, ctx, event);
  if (afterLifecycle) return afterLifecycle;

  if (event.type === "queue_update") {
    return { ...session, queue: reconcileQueueWithPiEvent(session.queue ?? [], event) };
  }

  const afterHeader = reduceSessionHeaderEvent(session, event);
  if (afterHeader) return afterHeader;

  const afterUserMessage = reduceUserMessageEvent(session, ctx, event);
  if (afterUserMessage) return afterUserMessage;

  let next = session;
  if (piEventIsSuccessfulCompaction(event)) {
    next = { ...next, contextUsage: null, tokenStats: undefined };
  }

  const usage = usageFromEvent(event);
  if (usage) {
    const settledUsage = event.type === "message" || event.type === "message_end";
    const totals = next.usageTotals ?? {
      input: 0,
      output: 0,
      cacheRead: 0,
      cacheWrite: 0,
      reasoning: 0,
      total: 0,
      cost: 0,
      calls: 0,
      compactions: 0,
    };
    next = {
      ...next,
      tokenStats: usage,
      usageTotals: settledUsage
        ? {
            ...totals,
            input: totals.input + usage.read,
            output: totals.output + usage.write,
            total: totals.total + usage.current,
            calls: totals.calls + 1,
          }
        : totals,
    };
  }

  const afterToolResult = reduceToolResultMessageEvent(next, ctx, event);
  if (afterToolResult) return afterToolResult;

  // Turn finished: settle any still-"running" tool badges and drop the
  // transient per-call snapshots. Also un-dim any steer bubble still marked
  // pending — once the turn is over there is no further echo coming, so a
  // delivered-or-not steer must read as normal rather than stuck dimmed.
  if (isAgentEndEvent(event)) {
    // Canonical replay ignores turn boundaries: the settled log already
    // carries final tool statuses (toolResult messages), so finalizing here
    // would invent state the log doesn't have — and must not open a bubble.
    if (ctx.replay) return next;
    const target = resolveAssistantTarget(next, ctx);
    const settled = patchAssistantMessage(
      target.session,
      target.targetId,
      (msg) => ({
        ...msg,
        blocks: finalizeRunningToolBlocks(msg.blocks ?? []),
      }),
      ctx.replay,
    );
    return clearPendingUserMessages(settled);
  }

  const afterFinalMessage = reduceFinalAssistantMessageEvent(next, ctx, event);
  if (afterFinalMessage) return afterFinalMessage;

  if (!assistantPiEventAffectsBlocks(event)) return next;
  const target = resolveAssistantTarget(next, ctx);
  traceAgentReasoning("pi-event-applier.before", {
    sessionId: session.id,
    assistantId: target.targetId,
    event,
  });
  return patchAssistantMessage(
    target.session,
    target.targetId,
    (msg) => {
      const blocks = applyAssistantPiEventToBlocks(msg.blocks ?? [], event);
      traceAgentReasoning("pi-event-applier.after", {
        sessionId: session.id,
        assistantId: target.targetId,
        event,
        beforeBlocks: msg.blocks ?? [],
        afterBlocks: blocks,
      });
      return blocks ? { ...msg, blocks } : msg;
    },
    ctx.replay,
  );
}

/**
 * Canonical replay is a fold over the live reducer: reduce every logged event
 * into an empty session skeleton and project out the transcript fields.
 * `tokenStats` falls out of the reducer's usage/compaction branches (last
 * usage after the latest successful compaction boundary).
 */
export function foldSessionEvents(events: Record<string, unknown>[]): {
  messages: ChatMessage[];
  title: string | null;
  startedAt: string | null;
  modelId: string | null;
  tokenStats: Session["tokenStats"];
  usageTotals: Session["usageTotals"];
} {
  const ctx: SessionStreamContext = { liveAssistantIds: new Map(), replay: true };
  let session: Session = {
    id: "replay",
    piSessionId: null,
    title: "",
    messages: [],
    status: "idle",
    error: "",
    input: "",
  };
  for (const event of events) session = reduceSessionEvent(session, ctx, event);
  return {
    messages: session.messages,
    title: session.title || null,
    startedAt: session.startedAt ?? null,
    modelId: session.modelId ?? null,
    tokenStats: session.tokenStats,
    usageTotals: session.usageTotals,
  };
}

// Resolve (or create) the assistant bubble an event should land on — the
// controller's former external `ensureAssistantId`, expressed as part of the
// fold. The liveAssistantIds pin wins (React-commit lag bridge), then a
// still-valid activeAssistantId, then — live only — the transcript's last
// assistant bubble (reload-mid-turn reattach); otherwise a new bubble opens
// and becomes the active target. Canonical replay never adopts the last
// bubble: a settled log renders one bubble per settled message.
function resolveAssistantTarget(
  session: Session,
  ctx: SessionStreamContext,
): { session: Session; targetId: string } {
  // Validate the pin the same way the active id is validated below. An
  // unvalidated pin that outlived its bubble made patchAssistantMessage drop
  // every event on the floor while the seq cursor advanced anyway — the
  // follow-up-after-a-dropped-connection content loss.
  const pinnedId = ctx.liveAssistantIds.get(session.id);
  const pinned =
    pinnedId && messageIndexById(session.messages, pinnedId) >= 0 ? pinnedId : undefined;
  if (pinnedId && !pinned) ctx.liveAssistantIds.delete(session.id);
  // The active bubble is almost always the LAST message (bubbles append at the
  // end), so validate it by scanning backward — folding a long replayed log
  // must not rescan the whole transcript from the front for every event.
  const active =
    session.activeAssistantId && messageIndexById(session.messages, session.activeAssistantId) >= 0
      ? session.activeAssistantId
      : undefined;
  const existing = pinned ?? active ?? (ctx.replay ? undefined : lastAssistantId(session.messages));
  if (existing) {
    return {
      targetId: existing,
      session:
        session.activeAssistantId === existing
          ? session
          : { ...session, activeAssistantId: existing },
    };
  }
  const targetId = newId("assistant");
  return {
    targetId,
    session: {
      ...session,
      activeAssistantId: targetId,
      messages: [
        ...session.messages,
        { id: targetId, role: "assistant", text: "", blocks: [], timestamp: nowLabel() },
      ],
    },
  };
}

// Canonical `session` header and `model_change` entries carry session
// metadata, not transcript content.
function reduceSessionHeaderEvent(
  session: Session,
  event: Record<string, unknown>,
): Session | null {
  if (event.type === "session") {
    let next = session;
    if (!next.startedAt && typeof event.timestamp === "string") {
      next = { ...next, startedAt: event.timestamp };
    }
    const modelId = [event.modelId, event.model, event.model_id].find(
      (value): value is string => typeof value === "string",
    );
    if (!next.modelId && modelId) next = { ...next, modelId };
    const piSessionId = piSessionIdFromEvent(event);
    if (!next.piSessionId && piSessionId) next = { ...next, piSessionId };
    return next;
  }
  if (event.type === "model_change") {
    const modelId =
      typeof event.model === "string"
        ? event.model
        : typeof event.modelId === "string"
          ? event.modelId
          : null;
    if (!modelId || session.modelId === modelId) return session;
    return { ...session, modelId };
  }
  return null;
}

// Canonical settled tool result: attach it to the bubble that owns the tool
// call (scan back through the transcript), falling back to the current target
// bubble. Live tool results arrive as tool_execution_* events, so this fires
// on replayed/hydrated logs.
function reduceToolResultMessageEvent(
  session: Session,
  ctx: SessionStreamContext,
  event: Record<string, unknown>,
): Session | null {
  if (event.type !== "message" && event.type !== "message_end") return null;
  const msg = asRecord(event.message);
  if (msg?.role !== "toolResult") return null;
  const toolCallId =
    (typeof msg.toolCallId === "string" && msg.toolCallId) || String(event.toolCallId || "");
  if (!toolCallId) return session;
  const owner = assistantWithTool(session.messages, toolCallId);
  const target = owner ? { session, targetId: owner } : resolveAssistantTarget(session, ctx);
  const resultText = messageText(msg.content as string | Record<string, unknown>[] | undefined);
  const isError = Boolean(msg.isError);
  return patchAssistantMessage(
    target.session,
    target.targetId,
    (current) => ({
      ...current,
      blocks: upsertTool(
        current.blocks ?? [],
        toolCallId,
        (existing) => ({
          ...existing,
          status: isError ? "error" : "done",
          text: resultText || existing.text,
        }),
        () => ({
          kind: "tool",
          id: toolCallId,
          name: (typeof msg.toolName === "string" && msg.toolName) || "tool",
          status: isError ? "error" : "done",
          text: resultText,
        }),
      ),
    }),
    ctx.replay,
  );
}

function assistantWithTool(messages: ChatMessage[], toolCallId: string): string | null {
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = messages[index];
    const hasTool = (message.blocks ?? []).some(
      (block) => block.kind === "tool" && block.id === toolCallId,
    );
    if (message.role === "assistant" && hasTool) return message.id;
  }
  return null;
}

// Backward id lookup: patch/target lookups land on (or near) the last message,
// so scanning from the end is O(1) in practice instead of O(N) per event.
function messageIndexById(messages: ChatMessage[], id: string): number {
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    if (messages[index].id === id) return index;
  }
  return -1;
}

function lastAssistantId(messages: ChatMessage[]): string | undefined {
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    if (messages[index].role === "assistant") return messages[index].id;
  }
  return undefined;
}

/**
 * Patch one assistant bubble.
 *
 * The live path must copy: React holds the previous `messages` array and
 * compares identity to decide what re-renders, so mutating it in place would
 * make a streamed delta invisible.
 *
 * Canonical replay has no such reader. `foldSessionEvents` builds a private
 * session from an empty array and only the final result escapes, so every
 * intermediate copy is garbage the moment the next event lands. Skipping them
 * takes a 1600-message fold from 113ms to 66ms and flattens the superlinear
 * tail — the array copy was the part that grew with transcript length.
 */
function patchAssistantMessage(
  session: Session,
  assistantId: string,
  patch: (msg: ChatMessage) => ChatMessage,
  replay = false,
): Session {
  const index = messageIndexById(session.messages, assistantId);
  if (index < 0) return session;
  const current = session.messages[index];
  const next = patch(current);
  if (next === current) return session;
  if (replay) {
    session.messages[index] = next;
    return session;
  }
  const messages = session.messages.slice();
  messages[index] = next;
  return { ...session, messages };
}

function reduceUserMessageEvent(
  session: Session,
  ctx: SessionStreamContext,
  event: Record<string, unknown>,
): Session | null {
  const isCanonical = event.type === "message" || (ctx.replay && event.type === "message_end");
  if (!isCanonical && event.type !== "message_start" && event.type !== "message_end") return null;
  if (ctx.replay && event.type === "message_start") return session;
  const msg = event.message as { role?: string; content?: string | Record<string, unknown>[] };
  if (msg?.role !== "user") return null;
  const text = visibleUserTextFromPi(messageText(msg.content));

  // A canonical settled user message (replayed log / runtime hydration burst):
  // append it verbatim, close the previous turn's bubble, and derive the
  // session title from the first prompt. It must NOT open an optimistic
  // assistant bubble or touch liveAssistantIds — those are streaming-echo
  // concerns (the branches below).
  if (isCanonical) {
    let next = session.activeAssistantId ? { ...session, activeAssistantId: undefined } : session;
    if (!text) return next;
    if (!next.title) next = { ...next, title: sessionTitleFromPrompt(text) };
    return {
      ...next,
      messages: [
        ...next.messages,
        { id: newId("user"), role: "user", text, timestamp: nowLabel() },
      ],
    };
  }
  if (!text) return session;
  const queue = removeDeliveredQueuedMessage(session.queue ?? [], text);

  // This echo is Pi showing a steer message to the model. If the UI already
  // dropped it into the transcript optimistically (dimmed), clear `pending` so
  // it brightens to normal, and open the assistant bubble for the steered reply
  // — same as a freshly echoed mid-stream message, just without duplicating it.
  const pending = findPendingUserMessage(session.messages, text);
  if (pending) {
    const nextAssistantId = newId("assistant");
    ctx.liveAssistantIds.set(session.id, nextAssistantId);
    return {
      ...session,
      queue,
      activeAssistantId: nextAssistantId,
      messages: [
        ...session.messages.map((message) =>
          message.id === pending.id ? { ...message, pending: false, awaitingEcho: false } : message,
        ),
        { id: nextAssistantId, role: "assistant", text: "", blocks: [], timestamp: nowLabel() },
      ],
    };
  }

  if (hasMatchingLastUserMessage(session.messages, text)) {
    return { ...session, queue };
  }
  // A mid-stream user message (steer/follow-up) opens the next assistant
  // bubble; later events in this turn target it via ctx.liveAssistantIds.
  const nextAssistantId = newId("assistant");
  ctx.liveAssistantIds.set(session.id, nextAssistantId);
  return {
    ...session,
    queue,
    activeAssistantId: nextAssistantId,
    messages: [
      ...session.messages,
      { id: newId("user"), role: "user", text, timestamp: nowLabel() },
      { id: nextAssistantId, role: "assistant", text: "", blocks: [], timestamp: nowLabel() },
    ],
  };
}

// The optimistic steer bubble awaiting its runtime echo: an un-echoed user
// message whose text matches what Pi just delivered to the model.
//
// This keys off `awaitingEcho`, not `pending`. `pending` is cleared at
// agent_end for styling reasons, and agent_end fires once per low-level run —
// several times per prompt under auto-retry or compaction. Keying the dedupe
// on it meant that with two steers in flight, both lost their marker, both
// echoes missed, and both messages were appended a second time.
function findPendingUserMessage(messages: ChatMessage[], text: string): ChatMessage | undefined {
  const target = text.trim();
  return [...messages]
    .reverse()
    .find(
      (message) =>
        message.role === "user" &&
        (message.awaitingEcho === true || message.pending === true) &&
        message.text.trim() === target,
    );
}

/** Un-dim steer bubbles at the end of a run: delivered or not, a stuck-dimmed
 *  message reads as broken. Deliberately leaves `awaitingEcho` intact — the
 *  echo may still be in flight, and that marker is the only thing standing
 *  between a late echo and a duplicated bubble. */
function clearPendingUserMessages(session: Session): Session {
  if (!session.messages.some((message) => message.pending)) return session;
  return {
    ...session,
    messages: session.messages.map((message) =>
      message.pending ? { ...message, pending: false } : message,
    ),
  };
}

/** Once the whole prompt has settled no further echo is coming, so any bubble
 *  still waiting for one never got matched and must stop shadowing later
 *  messages that happen to share its text. */
export function clearAwaitingEchoUserMessages(session: Session): Session {
  if (!session.messages.some((message) => message.awaitingEcho)) return session;
  return {
    ...session,
    messages: session.messages.map((message) =>
      message.awaitingEcho ? { ...message, awaitingEcho: false } : message,
    ),
  };
}

function reduceFinalAssistantMessageEvent(
  session: Session,
  ctx: SessionStreamContext,
  event: Record<string, unknown>,
): Session | null {
  if (event.type !== "message" && event.type !== "message_end") return null;
  const msg = asRecord(event.message);
  if (msg?.role !== "assistant") return null;
  const content = finalMessageContent(msg.content);
  const stopReason = typeof msg.stopReason === "string" ? msg.stopReason : undefined;

  if (ctx.replay) {
    const blocks = blocksFromMessageContent(content);
    const text = messageTextFromBlocks(blocks);
    const target = resolveAssistantTarget(session, ctx);
    const patched = patchAssistantMessage(
      target.session,
      target.targetId,
      (current) => reconcileFinalAssistantMessage(current, text, blocks),
      ctx.replay,
    );
    ctx.liveAssistantIds.delete(session.id);
    return { ...patched, activeAssistantId: undefined };
  }

  const errorMessage = assistantFailureText(msg, stopReason);
  const blocks = blocksFromMessageContent(content, { errorMessage });
  const text = messageTextFromBlocks(blocks);
  const target = resolveAssistantTarget(session, ctx);
  let next = patchAssistantMessage(
    target.session,
    target.targetId,
    (current) => reconcileFinalAssistantMessage(current, text, blocks),
    ctx.replay,
  );
  if (errorMessage) next = { ...next, error: errorMessage };
  return next;
}

function assistantFailureText(
  message: Record<string, unknown>,
  stopReason: string | undefined,
): string {
  // Only a genuine error is a failure. "aborted" (Stop pressed / navigated away)
  // is a clean stop and must produce no error text.
  if (stopReason !== "error") return "";
  const raw = [message.errorMessage, message.error]
    .find((value): value is string => typeof value === "string" && value.trim().length > 0)
    ?.trim();
  if (!raw) return "Assistant turn failed.";
  return raw;
}

function appendFailureBlock(blocks: AssistantBlock[], text: string): AssistantBlock[] {
  if (blocks.some((block) => block.kind === "event" && block.text === text)) return blocks;
  return [...blocks, { kind: "event", id: newId("error"), text }];
}

function finalMessageContent(value: unknown): string | Array<Record<string, unknown>> | undefined {
  if (typeof value === "string") return value;
  if (!Array.isArray(value)) return undefined;
  return value.flatMap((part) => {
    const record = asRecord(part);
    return record ? [record] : [];
  });
}

function assistantHasGeneratedBlocks(blocks: AssistantBlock[]): boolean {
  return blocks.some((block) => {
    if (block.kind === "event") return false;
    if (block.kind === "tool") {
      return Boolean(block.text || block.argsText || block.resultText || block.name);
    }
    return isMeaningfulAssistantText(block.text);
  });
}

function reconcileFinalAssistantMessage(
  current: ChatMessage,
  text: string,
  incomingBlocks: AssistantBlock[],
): ChatMessage {
  const existingBlocks = current.blocks ?? [];
  if (!assistantHasGeneratedBlocks(existingBlocks)) {
    return { ...current, text, blocks: incomingBlocks };
  }
  let blocks = reconcileMissingTools(existingBlocks, incomingBlocks);
  blocks = reconcileSettledTextKind(blocks, incomingBlocks, "thinking");
  blocks = reconcileSettledTextKind(blocks, incomingBlocks, "text");
  for (const block of incomingBlocks) {
    if (block.kind !== "event") continue;
    if (blocks.some((existing) => existing.kind === "event" && existing.text === block.text)) {
      continue;
    }
    blocks = [...blocks, block];
  }
  return blocks === existingBlocks
    ? current
    : { ...current, blocks, text: messageTextFromBlocks(blocks) };
}

function reconcileMissingTools(
  existingBlocks: AssistantBlock[],
  incomingBlocks: AssistantBlock[],
): AssistantBlock[] {
  const existingIds = new Set(
    existingBlocks.filter((block) => block.kind === "tool").map((block) => block.id),
  );
  const missing = incomingBlocks.filter(
    (block) => block.kind === "tool" && !existingIds.has(block.id),
  );
  return missing.length ? [...existingBlocks, ...missing] : existingBlocks;
}

function reconcileSettledTextKind(
  existingBlocks: AssistantBlock[],
  incomingBlocks: AssistantBlock[],
  kind: "text" | "thinking",
): AssistantBlock[] {
  const existing = joinedBlockText(existingBlocks, kind);
  const incoming = joinedBlockText(incomingBlocks, kind);
  if (!incoming || incoming === existing || existing.includes(incoming)) return existingBlocks;
  if (!existing) {
    const additions = incomingBlocks.filter((block) => block.kind === kind);
    return additions.length ? [...existingBlocks, ...additions] : existingBlocks;
  }
  const matchingIndex = existingBlocks.findLastIndex(
    (block) => block.kind === kind && incoming.startsWith(block.text),
  );
  const matchingBlock = existingBlocks[matchingIndex];
  if (matchingBlock && (matchingBlock.kind === "text" || matchingBlock.kind === "thinking")) {
    const suffix = incoming.slice(matchingBlock.text.length);
    if (!suffix) return existingBlocks;
    const next = existingBlocks.slice();
    next[matchingIndex] = { ...matchingBlock, text: matchingBlock.text + suffix };
    return next;
  }
  if (!incoming.startsWith(existing)) {
    const addition = incomingBlocks.find((block) => block.kind === kind);
    return addition ? [...existingBlocks, addition] : existingBlocks;
  }
  const suffix = incoming.slice(existing.length);
  if (!suffix) return existingBlocks;
  const index = existingBlocks.findLastIndex((block) => block.kind === kind);
  const block = existingBlocks[index];
  if (!block || (block.kind !== "text" && block.kind !== "thinking")) return existingBlocks;
  const next = existingBlocks.slice();
  next[index] = { ...block, text: block.text + suffix };
  return next;
}

function joinedBlockText(blocks: AssistantBlock[], kind: "text" | "thinking"): string {
  return blocks
    .filter((block) => block.kind === kind)
    .map((block) => block.text)
    .filter(isMeaningfulAssistantText)
    .join("");
}

function isMeaningfulAssistantText(text: string): boolean {
  const trimmed = text.trim();
  return Boolean(trimmed && !/^(?:\.{3}|…)+$/.test(trimmed));
}

function hasMatchingLastUserMessage(messages: ChatMessage[], text: string): boolean {
  const lastUser = [...messages].reverse().find((entry) => entry.role === "user");
  return Boolean(
    lastUser &&
    (lastUser.text === text ||
      text.includes(lastUser.text) ||
      Boolean(text && lastUser.text.includes(text)) ||
      Boolean(!text && lastUser.attachments?.length)),
  );
}

function stringArray(value: unknown): string[] {
  return Array.isArray(value)
    ? value.filter((item): item is string => typeof item === "string" && item.trim().length > 0)
    : [];
}

function queueDisplayText(text: string): string {
  return visibleUserTextFromPi(text) || text.trim();
}

function queueKey(mode: QueuedMessage["mode"], text: string): string {
  return `${mode}:${queueDisplayText(text)}`;
}

function consumePending(
  pending: Map<string, string[]>,
  mode: QueuedMessage["mode"],
  text: string,
): string | null {
  const key = queueKey(mode, text);
  const values = pending.get(key);
  if (!values || values.length === 0) return null;
  const [value, ...remaining] = values;
  if (remaining.length > 0) pending.set(key, remaining);
  else pending.delete(key);
  return value ?? null;
}

function reconcileQueueWithPiEvent(
  queue: QueuedMessage[],
  event: Record<string, unknown>,
): QueuedMessage[] {
  if (event.type !== "queue_update") return queue;
  const pending = new Map<string, string[]>();
  const addPending = (mode: QueuedMessage["mode"], messages: string[]) => {
    for (const text of messages) {
      const key = queueKey(mode, text);
      pending.set(key, [...(pending.get(key) ?? []), text]);
    }
  };
  addPending("follow_up", stringArray(event.followUp));

  const next = queue.flatMap((item) => {
    if (item.mode !== "follow_up") return [];
    const acceptedByPi = consumePending(pending, item.mode, item.text);
    if (acceptedByPi) return [{ ...item, text: queueDisplayText(acceptedByPi), sent: true }];
    return item.sent ? [] : [item];
  });

  for (const [key, messages] of pending) {
    const separator = key.indexOf(":");
    const mode = key.slice(0, separator) as QueuedMessage["mode"];
    for (const text of messages) {
      next.push({ id: newId("queue"), mode, text: queueDisplayText(text), sent: true });
    }
  }
  return next;
}

function removeDeliveredQueuedMessage(
  queue: QueuedMessage[],
  deliveredText: string,
): QueuedMessage[] {
  const delivered = queueDisplayText(deliveredText);
  const index = queue.findIndex((item) => queueDisplayText(item.text) === delivered);
  if (index === -1) return queue;
  return [...queue.slice(0, index), ...queue.slice(index + 1)];
}
