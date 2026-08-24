import type { OpenAgentSession } from "@/features/agent/session-index";
import type { ComputerTab } from "@/features/agent/tools/types";

export type WorkbenchTab = {
  id: string;
  kind: "task" | "tool";
  title: string;
  resourceId: string;
  groupId: string;
  groupTitle: string;
  href?: string;
  projectId?: string;
  sessionId?: string;
  threadId?: string;
  tool?: ComputerTab;
  status?: string;
};

export type WorkbenchState = {
  tabs: WorkbenchTab[];
  activeId: string | null;
  closedTabIds: string[];
};

export const COMPUTER_TAB_TITLES: Record<ComputerTab, string> = {
  status: "Session",
  tools: "Tools",
  "side-chat": "Side chat",
  browser: "Browser",
  files: "Files",
  diff: "Review",
  terminal: "Terminal",
};

export function taskIdentity(session: Pick<OpenAgentSession, "id" | "threadId">): string {
  return session.threadId ?? session.id;
}

export function taskTab(session: OpenAgentSession): WorkbenchTab {
  const identity = taskIdentity(session);
  const title = session.title.trim() || "New task";
  const query = new URLSearchParams({ project: session.projectId, replace: "1" });
  if (session.threadId) query.set("session", session.threadId);
  return {
    id: `task:${identity}`,
    kind: "task",
    title: "Chat",
    resourceId: session.id,
    groupId: `thread:${identity}`,
    groupTitle: title,
    href: `/agent?${query.toString()}`,
    projectId: session.projectId,
    sessionId: session.id,
    ...(session.threadId ? { threadId: session.threadId } : {}),
    status: session.status,
  };
}

export function emptyTaskTab(projectId?: string | null): WorkbenchTab {
  const scope = projectId?.trim() || "workspace";
  const query = new URLSearchParams({ new: "1", replace: "1" });
  if (projectId) query.set("project", projectId);
  return {
    id: `task:new:${scope}`,
    kind: "task",
    title: "Chat",
    resourceId: "new",
    groupId: `new:${scope}`,
    groupTitle: "New task",
    href: `/agent?${query.toString()}`,
    ...(projectId ? { projectId } : {}),
  };
}

export function toolTab(tool: ComputerTab, scope: WorkbenchTab | OpenAgentSession): WorkbenchTab {
  const source = "kind" in scope ? scope : taskTab(scope);
  return {
    id: `tool:${source.groupId}:${tool}`,
    kind: "tool",
    title: COMPUTER_TAB_TITLES[tool],
    resourceId: tool,
    groupId: source.groupId,
    groupTitle: source.groupTitle,
    href: source.href,
    ...(source.projectId ? { projectId: source.projectId } : {}),
    ...(source.sessionId ? { sessionId: source.sessionId } : {}),
    ...(source.threadId ? { threadId: source.threadId } : {}),
    tool,
  };
}

export function tabMatchesSession(
  tab: WorkbenchTab,
  session: Pick<OpenAgentSession, "id" | "threadId">,
): boolean {
  return (
    tab.sessionId === session.id ||
    tab.resourceId === session.id ||
    Boolean(session.threadId && tab.threadId === session.threadId)
  );
}

export function upsertTab(tabs: readonly WorkbenchTab[], tab: WorkbenchTab): WorkbenchTab[] {
  const index = tabs.findIndex((candidate) => candidate.id === tab.id);
  if (index >= 0) {
    const current = tabs[index];
    if (JSON.stringify(current) === JSON.stringify(tab)) return [...tabs];
    const next = [...tabs];
    next[index] = tab;
    return next;
  }
  const groupIndexes = tabs.flatMap((candidate, candidateIndex) =>
    candidate.groupId === tab.groupId ? [candidateIndex] : [],
  );
  if (groupIndexes.length === 0) return [...tabs, tab];
  const next = [...tabs];
  const insertAt = tab.kind === "task" ? groupIndexes[0] : groupIndexes.at(-1)! + 1;
  next.splice(insertAt, 0, tab);
  return next;
}

export function reorderTabs(
  tabs: readonly WorkbenchTab[],
  sourceId: string,
  targetId: string,
): WorkbenchTab[] {
  if (sourceId === targetId) return [...tabs];
  const sourceIndex = tabs.findIndex((tab) => tab.id === sourceId);
  const targetIndex = tabs.findIndex((tab) => tab.id === targetId);
  if (sourceIndex < 0 || targetIndex < 0) return [...tabs];
  if (tabs[sourceIndex]?.groupId !== tabs[targetIndex]?.groupId) return [...tabs];
  if (tabs[sourceIndex]?.kind === "task" || tabs[targetIndex]?.kind === "task") return [...tabs];
  const next = [...tabs];
  const [source] = next.splice(sourceIndex, 1);
  if (!source) return [...tabs];
  const insertAt = sourceIndex < targetIndex ? targetIndex - 1 : targetIndex;
  next.splice(insertAt, 0, source);
  return next;
}
