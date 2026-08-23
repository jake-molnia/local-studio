"use client";

import { useCallback, useMemo, useState, type KeyboardEvent } from "react";
import { Plus, TerminalSquare } from "@/ui/icon-registry";
import { CloseIcon } from "@/ui/icons";
import {
  rememberPersistentTerminalOwner,
  removePersistentTerminalOwner,
  selectPersistentTerminalOwner,
  usePersistentTerminalOwners,
  type TerminalOwnersSnapshot,
} from "@/features/agent/ui/use-persistent-terminal-owners";
import { normalizeBrowserInput } from "@/features/agent/tools/browser-url";
import {
  sanitizeBrowserPaneUrl,
  sanitizeLocalFileUrl,
} from "@/features/agent/sanitize-embedded-browser-url";
import { useTools } from "@/features/agent/tools/context";
import type { GitSummary, Project } from "@/features/agent/projects/types";
import type { Session } from "@/features/agent/runtime/types";
import { makeFreshTab } from "@/features/agent/messages/helpers";
import type { AgentModel } from "@/features/agent/workspace/types";
import {
  terminalKeysMatch,
  terminalOwnerFor,
  terminalOwnerLabel,
} from "@/features/agent/terminal-owners";
import { ComputerTabPanel, type SideChatTabsUpdater } from "@/features/agent/ui/computer-tab-panel";
import { PersistentTerminals } from "@/features/agent/ui/persistent-terminals";
import type { WorkspaceHandles } from "@/features/agent/ui/use-workspace";
import { useMountSubscription } from "@/hooks/use-mount-subscription";

type AgentBrowserPanelHandles = Pick<
  WorkspaceHandles,
  "compactFocusedSession" | "updateDetachedSession" | "removeDetachedSession"
>;

type AgentBrowserPanelProps = {
  handles: AgentBrowserPanelHandles;
  activeProject: Project | null;
  focusedSession: Session | null;
  sessions: Session[];
  activeModelId: string;
  activeModel: AgentModel | null;
  models: AgentModel[];
  modelsLoading: boolean;
  gitSummary?: GitSummary | null;
};

function createSideChatSession(
  activeProject: Project | null,
  focusedSession: Session | null,
  activeModelId: string,
): Session {
  const tab = makeFreshTab();
  return {
    ...tab,
    title: "Side chat",
    cwd: focusedSession?.cwd ?? activeProject?.path,
    projectId: focusedSession?.projectId ?? activeProject?.id,
    modelId: focusedSession?.modelId ?? activeModelId,
  };
}

function terminalBridge() {
  return (
    window as unknown as {
      localStudioDesktop?: { terminal?: { closeOwner?: (ownerKey: string) => Promise<void> } };
    }
  ).localStudioDesktop?.terminal;
}

function closePersistedTerminalOwner(ownerKey: string) {
  const owner = removePersistentTerminalOwner(ownerKey);
  if (owner) void terminalBridge()?.closeOwner?.(owner.mountKey);
}

function acceptedBrowserUrl(url: string): string | null {
  return /^file:\/\//i.test(url) ? sanitizeLocalFileUrl(url) : sanitizeBrowserPaneUrl(url);
}

export function AgentBrowserPanel({
  handles,
  activeProject,
  focusedSession,
  sessions,
  activeModelId,
  activeModel,
  models,
  modelsLoading,
  gitSummary,
}: AgentBrowserPanelProps) {
  const tools = useTools();
  const sideChatScope =
    focusedSession?.piSessionId ??
    focusedSession?.id ??
    `project:${activeProject?.id ?? "workspace"}`;
  const [sideChatSeeds, setSideChatSeeds] = useState<Record<string, Session>>({});
  const fallbackSideChatSeed = useMemo(
    () => createSideChatSession(activeProject, focusedSession, activeModelId),
    [activeModelId, activeProject, focusedSession, sideChatScope],
  );
  const sideChatSeed = sideChatSeeds[sideChatScope] ?? fallbackSideChatSeed;
  useMountSubscription(() => {
    setSideChatSeeds((current) =>
      current[sideChatScope] ? current : { ...current, [sideChatScope]: fallbackSideChatSeed },
    );
  }, [fallbackSideChatSeed.id, sideChatScope]);
  const sideChatSession =
    sessions.find((session) => session.id === sideChatSeed.id) ?? sideChatSeed;
  const terminalOwner = useMemo(
    () => terminalOwnerFor(activeProject, focusedSession),
    [activeProject, focusedSession],
  );
  const terminalState = usePersistentTerminalOwners(
    tools.computer.open && tools.computer.tab === "terminal",
    terminalOwner,
  );
  const visibleTerminalState = useMemo<TerminalOwnersSnapshot>(() => {
    const owners = terminalOwner
      ? terminalState.owners.filter((owner) =>
          terminalKeysMatch(owner.matchKeys, terminalOwner.matchKeys),
        )
      : [];
    const activeOwnerKey = owners.some((owner) => owner.mountKey === terminalState.activeOwnerKey)
      ? terminalState.activeOwnerKey
      : (owners[0]?.mountKey ?? null);
    return { owners, activeOwnerKey };
  }, [terminalOwner, terminalState]);
  const openTerminalForFocusedSession = useCallback(() => {
    if (terminalOwner) rememberPersistentTerminalOwner(terminalOwner, { select: true });
    tools.setComputerTab("terminal");
  }, [terminalOwner, tools]);
  const selectTerminalOwner = useCallback(
    (ownerKey: string) => {
      selectPersistentTerminalOwner(ownerKey);
      tools.setComputerTab("terminal");
    },
    [tools],
  );
  const closeTerminalOwner = useCallback(
    (ownerKey: string) => {
      closePersistedTerminalOwner(ownerKey);
      if (visibleTerminalState.owners.length <= 1) tools.closeComputerTab("terminal");
    },
    [visibleTerminalState.owners.length, tools],
  );
  const handleComputerKeyDown = useCallback(
    (event: KeyboardEvent<HTMLElement>) => {
      if (!(event.metaKey || event.ctrlKey) || !event.altKey) return;
      const index = Number(event.key) - 1;
      if (!Number.isInteger(index) || index < 0) return;
      const owner = visibleTerminalState.owners[index];
      if (!owner) return;
      event.preventDefault();
      selectTerminalOwner(owner.mountKey);
    },
    [selectTerminalOwner, visibleTerminalState.owners],
  );
  const navigateBrowser = (value: string) => {
    const next = normalizeBrowserInput(value, focusedSession?.cwd ?? activeProject?.path ?? "");
    if (!next) return;
    const accepted = acceptedBrowserUrl(next);
    if (!accepted) return;
    tools.setBrowserUrl(accepted, accepted);
    if (/^file:\/\//i.test(accepted)) return;
    void fetch("/api/agent/browser/navigate", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ url: accepted }),
    }).catch(() => undefined);
  };
  const openSideChat = useCallback(() => {
    handles.updateDetachedSession(sideChatSeed, (current) =>
      current.messages.length
        ? current
        : {
            ...current,
            status: current.status === "loading" ? "idle" : current.status,
            cwd: focusedSession?.cwd ?? activeProject?.path,
            projectId: focusedSession?.projectId ?? activeProject?.id,
            modelId: current.modelId || focusedSession?.modelId || activeModelId,
          },
    );
    tools.setComputerTab("side-chat");
  }, [activeModelId, activeProject, focusedSession, handles, sideChatSeed, tools]);
  const updateSideChatTabs = useCallback(
    (nextTabsOrUpdater: SideChatTabsUpdater) => {
      handles.updateDetachedSession(sideChatSeed, (current) => {
        const nextTabs =
          typeof nextTabsOrUpdater === "function"
            ? nextTabsOrUpdater([current])
            : nextTabsOrUpdater;
        return nextTabs.at(-1) ?? current;
      });
    },
    [handles, sideChatSeed],
  );
  const renameSideChat = useCallback(
    (tabId: string, title: string) => {
      handles.updateDetachedSession(sideChatSeed, (current) =>
        current.id === tabId ? { ...current, title } : current,
      );
    },
    [handles, sideChatSeed],
  );
  const closeSideChat = useCallback(() => {
    handles.removeDetachedSession(sideChatSeed.id);
    setSideChatSeeds((current) => ({
      ...current,
      [sideChatScope]: createSideChatSession(activeProject, focusedSession, activeModelId),
    }));
    tools.closeComputerTab("side-chat");
  }, [
    activeModelId,
    activeProject,
    focusedSession,
    handles,
    sideChatScope,
    sideChatSeed.id,
    tools,
  ]);
  return (
    <section
      className={`agent-computer-panel ${tools.computer.open ? "relative flex" : "hidden"} min-h-0 min-w-0 flex-1 flex-col bg-(--color-panel)`}
      tabIndex={-1}
      onKeyDown={handleComputerKeyDown}
    >
      {tools.computer.tab === "terminal" ? (
        <TerminalOwnerBar
          terminalState={visibleTerminalState}
          onOpenCurrentTerminal={openTerminalForFocusedSession}
          onSelectTerminalOwner={selectTerminalOwner}
          onCloseTerminalOwner={closeTerminalOwner}
        />
      ) : null}

      <ComputerTabPanel
        activeModel={activeModel}
        activeModelId={activeModelId}
        activeProject={activeProject}
        focusedSession={focusedSession}
        gitSummary={gitSummary}
        models={models}
        modelsLoading={modelsLoading}
        onCloseSideChat={closeSideChat}
        onCompactSession={handles.compactFocusedSession}
        onNavigateBrowser={navigateBrowser}
        onOpenSideChat={openSideChat}
        onOpenTerminal={openTerminalForFocusedSession}
        onRenameSideChat={renameSideChat}
        onUpdateSideChatTabs={updateSideChatTabs}
        sessions={sessions}
        sideChatSession={sideChatSession}
        tools={tools}
      />

      <PersistentTerminals
        active={tools.computer.open && tools.computer.tab === "terminal"}
        activeOwnerKey={visibleTerminalState.activeOwnerKey}
        terminals={terminalState.owners}
      />
    </section>
  );
}
function TerminalOwnerBar({
  terminalState,
  onOpenCurrentTerminal,
  onSelectTerminalOwner,
  onCloseTerminalOwner,
}: {
  terminalState: TerminalOwnersSnapshot;
  onOpenCurrentTerminal: () => void;
  onSelectTerminalOwner: (ownerKey: string) => void;
  onCloseTerminalOwner: (ownerKey: string) => void;
}) {
  return (
    <div className="flex h-7 shrink-0 items-center gap-1 border-b border-(--border) bg-(--color-header) px-1">
      <div className="flex min-w-0 flex-1 items-center gap-0.5 overflow-x-auto [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
        {terminalState.owners.map((owner, index) => {
          const label = terminalOwnerLabel(owner, index);
          const selected = terminalState.activeOwnerKey === owner.mountKey;
          const shortcut = index < 9 ? `⌘⌥${index + 1}` : undefined;
          return (
            <div
              key={owner.mountKey}
              title={shortcut ? `${label} (${shortcut})` : label}
              className={`group flex h-6 min-w-0 max-w-52 items-center rounded-[var(--rad-sm)] ${
                selected ? "bg-(--active) text-(--fg)" : "text-(--dim) hover:bg-(--hover)"
              }`}
            >
              <button
                type="button"
                onClick={() => onSelectTerminalOwner(owner.mountKey)}
                className="flex h-full min-w-0 flex-1 items-center gap-1.5 px-2 text-[11px]"
              >
                <TerminalSquare className="h-3 w-3 shrink-0" />
                <span className="truncate">{label}</span>
              </button>
              <button
                type="button"
                onClick={() => onCloseTerminalOwner(owner.mountKey)}
                className="mr-0.5 flex h-5 w-5 shrink-0 items-center justify-center rounded-[3px] opacity-0 hover:bg-(--fg)/8 group-hover:opacity-80 focus-visible:opacity-100"
                aria-label={`Close ${label}`}
              >
                <CloseIcon className="h-2.5 w-2.5" />
              </button>
            </div>
          );
        })}
      </div>
      <button
        type="button"
        onClick={onOpenCurrentTerminal}
        className="flex h-6 w-6 shrink-0 items-center justify-center rounded-[var(--rad-sm)] text-(--dim) hover:bg-(--hover) hover:text-(--fg)"
        title="Open terminal for current task"
        aria-label="Open terminal for current task"
      >
        <Plus className="h-3.5 w-3.5" />
      </button>
    </div>
  );
}
