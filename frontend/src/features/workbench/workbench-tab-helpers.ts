import type { KeyboardEvent as ReactKeyboardEvent } from "react";
import {
  emptyTaskTab,
  tabMatchesSession,
  taskTab,
  toolTab,
  type WorkbenchState,
  type WorkbenchTab,
} from "@/features/workbench/model";
import type { OpenAgentSession } from "@/features/agent/session-index";
import { cleanSessionTitle } from "@shared/agent/session-title";
import type { AggregatedSession } from "@shared/agent/session-summary";
import type { ComputerTab } from "@/features/agent/tools/types";

export type PendingTool = {
  tab: WorkbenchTab;
  tool: ComputerTab;
};

export type WorkbenchNavigation = {
  focusedSession: OpenAgentSession | null;
  currentProjectId: string | null;
  requestedSessionId: string | null;
  wantsNewTask: boolean;
  navigationKey: string;
};

export type DraftPromotion = {
  projectId: string | null;
  excludedSessionIds: Set<string>;
  createdAfter: number;
};

export type SearchParamsLike = {
  get(name: string): string | null;
};

export function initialState(projectId?: string | null): WorkbenchState {
  const tab = emptyTaskTab(projectId);
  return { tabs: [tab], activeId: tab.id, closedTabIds: [] };
}

export function dedupeTabs(tabs: readonly WorkbenchTab[]): WorkbenchTab[] {
  const order: string[] = [];
  const byId = new Map<string, WorkbenchTab>();
  for (const tab of tabs) {
    if (!byId.has(tab.id)) order.push(tab.id);
    byId.set(tab.id, tab);
  }
  return order.flatMap((id) => {
    const tab = byId.get(id);
    return tab ? [tab] : [];
  });
}

export function sessionForTab(
  tab: WorkbenchTab,
  sessions: readonly OpenAgentSession[],
): OpenAgentSession | null {
  return sessions.find((session) => tabMatchesSession(tab, session)) ?? null;
}

export function sessionIdentity(session: OpenAgentSession): string {
  return session.threadId ?? session.id;
}

export function draftPromotion(
  projectId: string | null,
  sessions: readonly OpenAgentSession[],
): DraftPromotion {
  return {
    projectId,
    createdAfter: Date.now(),
    excludedSessionIds: new Set(
      sessions.flatMap((session) => [session.id, ...(session.threadId ? [session.threadId] : [])]),
    ),
  };
}

export function trackDraftPromotion(
  pending: DraftPromotion | null,
  wantsNewTask: boolean,
  projectId: string | null,
  sessions: readonly OpenAgentSession[],
): DraftPromotion | null {
  if (!wantsNewTask) return pending;
  return !pending || pending.projectId !== projectId
    ? draftPromotion(projectId, sessions)
    : pending;
}

export function initialDraftPromotion(
  wantsNewTask: boolean,
  projectId: string | null,
  sessions: readonly OpenAgentSession[],
): DraftPromotion | null {
  return wantsNewTask ? draftPromotion(projectId, sessions) : null;
}

export function canPromoteDraft(
  pending: DraftPromotion | null,
  session: OpenAgentSession | null,
  tabs: readonly WorkbenchTab[],
): boolean {
  if (!pending || !session || pending.projectId !== session.projectId) return false;
  if (pending.excludedSessionIds.has(sessionIdentity(session))) return false;
  const sessionStartedAt = Date.parse(session.startedAt ?? session.updatedAt);
  if (Number.isFinite(sessionStartedAt) && sessionStartedAt < pending.createdAfter - 2_000) {
    return false;
  }
  const draftGroupId = emptyTaskTab(session.projectId).groupId;
  return tabs.some((tab) => tab.groupId === draftGroupId);
}

export function validWorkbenchTabs(
  tabs: readonly WorkbenchTab[],
  sessions: readonly OpenAgentSession[],
  knownSessionIds: ReadonlySet<string> | null,
  projectIds: ReadonlySet<string>,
  projectsLoaded: boolean,
): WorkbenchTab[] {
  return tabs.filter((tab) => {
    if (tab.projectId && projectsLoaded && !projectIds.has(tab.projectId)) return false;
    if (tab.groupId.startsWith("new:")) return true;
    if (sessionForTab(tab, sessions)) return true;
    if (!knownSessionIds) return true;
    const identity = tab.threadId ?? tab.sessionId;
    return Boolean(identity && knownSessionIds.has(identity));
  });
}

export function resolveWorkbenchNavigation(
  searchParams: SearchParamsLike,
  openSessions: readonly OpenAgentSession[],
  selectedProjectId: string | null,
): WorkbenchNavigation {
  const requestedSessionId = searchParams.get("session");
  const requestedSession = requestedSessionId
    ? (openSessions.find(
        (session) => session.threadId === requestedSessionId || session.id === requestedSessionId,
      ) ?? null)
    : null;
  const wantsNewTask = searchParams.get("new") === "1";
  const focusedSession =
    wantsNewTask || (requestedSessionId && !requestedSession)
      ? null
      : (requestedSession ??
        openSessions.find((session) => session.focused) ??
        openSessions.at(-1) ??
        null);
  const currentProjectId =
    focusedSession?.projectId ?? searchParams.get("project") ?? selectedProjectId;
  return {
    focusedSession,
    currentProjectId,
    requestedSessionId,
    wantsNewTask,
    navigationKey: [
      searchParams.get("project"),
      searchParams.get("session"),
      searchParams.get("new"),
      searchParams.get("open"),
      wantsNewTask ? "new" : (focusedSession?.id ?? "pending"),
    ].join(":"),
  };
}

export function historicalTaskTab(session: AggregatedSession): WorkbenchTab {
  const title = cleanSessionTitle(session.firstUserMessage) || `Session ${session.id.slice(0, 8)}`;
  const query = new URLSearchParams({
    project: session.projectId,
    session: session.id,
    replace: "1",
  });
  return {
    id: `task:${session.id}`,
    kind: "task",
    title: "Chat",
    resourceId: session.id,
    groupId: `thread:${session.id}`,
    groupTitle: title,
    href: `/agent?${query.toString()}`,
    projectId: session.projectId,
    threadId: session.id,
  };
}

export function pendingHistoricalTaskTab(
  sessionId: string,
  projectId: string | null,
): WorkbenchTab {
  const query = new URLSearchParams({ session: sessionId, replace: "1" });
  if (projectId) query.set("project", projectId);
  return {
    id: `task:${sessionId}`,
    kind: "task",
    title: "Chat",
    resourceId: sessionId,
    groupId: `thread:${sessionId}`,
    groupTitle: "Loading task",
    href: `/agent?${query.toString()}`,
    ...(projectId ? { projectId } : {}),
    threadId: sessionId,
  };
}

export function navigationTaskFor(
  focusedSession: OpenAgentSession | null,
  requestedSessionId: string | null,
  projectId: string | null,
  catalog: ReadonlyMap<string, AggregatedSession> | null,
): WorkbenchTab {
  if (focusedSession) return taskTab(focusedSession);
  if (!requestedSessionId) return emptyTaskTab(projectId);
  const historical = catalog?.get(requestedSessionId);
  return historical
    ? historicalTaskTab(historical)
    : pendingHistoricalTaskTab(requestedSessionId, projectId);
}

export function catalogSessionIds(
  catalog: ReadonlyMap<string, AggregatedSession> | null,
): ReadonlySet<string> | null {
  return catalog ? new Set(catalog.keys()) : null;
}

export function closeFocusTarget(
  activeId: string | null,
  closingId: string,
  nextActive: WorkbenchTab | null,
  fallback: WorkbenchTab,
): WorkbenchTab | null {
  return activeId === closingId ? (nextActive ?? fallback) : null;
}

export function promoteDraftTabs(
  tabs: readonly WorkbenchTab[],
  session: OpenAgentSession,
): { tabs: WorkbenchTab[]; idRemap: Map<string, string> } {
  const draft = emptyTaskTab(session.projectId);
  const idRemap = new Map<string, string>();
  const promoted = tabs.map((tab) => {
    if (tab.groupId !== draft.groupId) return tab;
    const next = tab.kind === "task" ? taskTab(session) : toolTab(tab.tool!, session);
    idRemap.set(tab.id, next.id);
    return next;
  });
  return { tabs: dedupeTabs(promoted), idRemap };
}

export function projectInitial(name: string): string {
  return name.trim().charAt(0).toUpperCase() || "W";
}

export function handleLauncherKeyDown(
  event: ReactKeyboardEvent<HTMLDivElement>,
  onDismiss: () => void,
) {
  if (event.key === "Escape") {
    event.preventDefault();
    event.stopPropagation();
    onDismiss();
    return;
  }
  if (event.target instanceof HTMLInputElement && event.key !== "ArrowDown") return;
  const items = [...event.currentTarget.querySelectorAll<HTMLElement>('[role="menuitem"]')];
  if (items.length === 0) return;
  const currentIndex = items.findIndex((item) => item === document.activeElement);
  let nextIndex: number | null = null;
  if (event.key === "ArrowDown") nextIndex = (currentIndex + 1 + items.length) % items.length;
  if (event.key === "ArrowUp") nextIndex = (currentIndex - 1 + items.length) % items.length;
  if (event.key === "Home") nextIndex = 0;
  if (event.key === "End") nextIndex = items.length - 1;
  if (nextIndex === null) return;
  event.preventDefault();
  items[nextIndex]?.focus();
}
