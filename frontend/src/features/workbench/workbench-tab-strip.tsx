"use client";

import {
  useMemo,
  useRef,
  useState,
  type DragEvent,
  type KeyboardEvent as ReactKeyboardEvent,
} from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { Menu, PanelLeftHollow, Plus } from "@/ui/icon-registry";
import { uniqueOpenSessions, useOpenSessions } from "@/features/agent/session-index";
import { useProjects } from "@/features/agent/projects/context";
import { useComputerTools, useToolsActions } from "@/features/agent/tools/context";
import { workspaceCommands } from "@/features/agent/workspace/commands";
import { hrefWithOpenNonce } from "@/features/agent/ui/projects-nav/helpers";
import { loadAggregatedSessionsOptional } from "@/features/agent/ui/sessions-command-effects";
import { SESSIONS_CHANGED_EVENT } from "@/lib/workspace-events";
import { useMountSubscription } from "@/hooks/use-mount-subscription";
import {
  emptyTaskTab,
  reorderTabs,
  tabMatchesSession,
  taskTab,
  toolTab,
  upsertTab,
  type WorkbenchState,
  type WorkbenchTab,
} from "@/features/workbench/model";
import { loadWorkbenchState, writeWorkbenchState } from "@/features/workbench/persistence";
import {
  WorkbenchLauncher,
  WorkbenchProjectTabList,
} from "@/features/workbench/workbench-tab-components";
import {
  canPromoteDraft,
  catalogSessionIds,
  closeFocusTarget,
  dedupeTabs,
  draftPromotion,
  initialDraftPromotion,
  initialState,
  navigationTaskFor,
  type PendingTool,
  type DraftPromotion,
  promoteDraftTabs,
  resolveWorkbenchNavigation,
  sessionForTab,
  sessionIdentity,
  trackDraftPromotion,
  validWorkbenchTabs,
} from "@/features/workbench/workbench-tab-helpers";
import { useAppStore } from "@/store";
import type { AggregatedSession } from "@shared/agent/session-summary";

function isEditableTarget(target: EventTarget | null): boolean {
  if (!(target instanceof HTMLElement)) return false;
  return Boolean(target.closest("input, textarea, select, [contenteditable='true']"));
}

export function WorkbenchTabStrip() {
  const searchParams = useSearchParams();
  const router = useRouter();
  const setMobileNavOpen = useAppStore((store) => store.setMobileNavOpen);
  const sidebarExpanded = useAppStore((store) => store.desktopSidebarPinnedOpen);
  const setSidebarExpanded = useAppStore((store) => store.setDesktopSidebarPinnedOpen);
  const projects = useProjects();
  const computer = useComputerTools();
  const tools = useToolsActions();
  const allOpenSessions = useOpenSessions();
  const openSessions = useMemo(() => uniqueOpenSessions(allOpenSessions), [allOpenSessions]);
  const {
    focusedSession,
    currentProjectId,
    requestedSessionId,
    wantsNewTask,
    navigationKey: agentNavigationKey,
  } = resolveWorkbenchNavigation(searchParams, openSessions, projects.selectedProjectId);
  const [state, setState] = useState<WorkbenchState>(() => initialState());
  const [hydrated, setHydrated] = useState(false);
  const [launcherOpen, setLauncherOpen] = useState(false);
  const [pendingTool, setPendingTool] = useState<PendingTool | null>(null);
  const [pendingTask, setPendingTask] = useState<WorkbenchTab | null>(null);
  const [sessionCatalog, setSessionCatalog] = useState<{
    sessions: ReadonlyMap<string, AggregatedSession> | null;
    version: number;
  }>({ sessions: null, version: 0 });
  const launcherRef = useRef<HTMLDivElement | null>(null);
  const draggedTabRef = useRef<string | null>(null);
  const tabElementsRef = useRef(new Map<string, HTMLButtonElement>());
  const lastAgentNavigationRef = useRef<string | null>(null);
  const draftPromotionRef = useRef<DraftPromotion | null>(
    initialDraftPromotion(wantsNewTask, currentProjectId, openSessions),
  );
  const previousComputerOpenRef = useRef(computer.open);
  const projectNames = new Map(projects.projects.map((project) => [project.id, project.name]));
  const navigationTask = navigationTaskFor(
    focusedSession,
    requestedSessionId,
    currentProjectId,
    sessionCatalog.sessions,
  );
  const currentSessionTabs = state.tabs.filter((tab) => tab.groupId === navigationTask.groupId);
  const sessionTabs = [
    ...currentSessionTabs.filter((tab) => tab.kind === "task"),
    ...currentSessionTabs.filter((tab) => tab.kind === "tool"),
  ];
  const orderedTabs = sessionTabs.some((tab) => tab.kind === "task")
    ? sessionTabs
    : [navigationTask, ...sessionTabs];
  const activeTabId = orderedTabs.some((tab) => tab.id === state.activeId)
    ? state.activeId
    : navigationTask.id;
  const sessionSyncKey = JSON.stringify({
    navigation: agentNavigationKey,
    projectId: currentProjectId,
    draftGroupIds: state.tabs
      .filter((tab) => tab.groupId.startsWith("new:"))
      .map((tab) => tab.groupId),
    pendingToolId: pendingTool?.tab.id,
    pendingTaskId: pendingTask?.id,
    sessionCatalogVersion: sessionCatalog.version,
    projectsLoaded: projects.loaded,
    projectIds: projects.projects.map((project) => project.id),
    sessions: openSessions.map((session) => ({
      id: session.id,
      threadId: session.threadId,
      projectId: session.projectId,
      title: session.title,
      status: session.status,
      focused: session.focused,
    })),
  });
  const computerSyncKey = JSON.stringify({
    open: computer.open,
    tab: computer.tab,
    tabs: computer.tabs,
    projectId: currentProjectId,
    sessionId: focusedSession?.id,
    threadId: focusedSession?.threadId,
    title: focusedSession?.title,
    scopeKey: computer.sessionKey,
  });
  const shortcutSyncKey = JSON.stringify({
    activeId: activeTabId,
    tabIds: orderedTabs.map((tab) => tab.id),
    projectId: currentProjectId,
    sessionId: focusedSession?.id,
    threadId: focusedSession?.threadId,
    pendingToolId: pendingTool?.tab.id,
    pendingTaskId: pendingTask?.id,
  });

  const activateTab = (tab: WorkbenchTab) => {
    setLauncherOpen(false);
    setState((current) => ({
      ...current,
      tabs: upsertTab(current.tabs, tab),
      activeId: tab.id,
      closedTabIds: current.closedTabIds.filter((id) => id !== tab.id),
    }));
    if (tab.kind === "task") {
      setPendingTool(null);
      tools.setComputerOpen(false);
      const session = sessionForTab(tab, openSessions);
      if (session && !session.focused) {
        setPendingTask(tab);
        workspaceCommands().focusSession(session.paneId, session.id, {
          replaceWorkspace: true,
        });
        if (tab.href) router.push(hrefWithOpenNonce(tab.href));
        return;
      }
      setPendingTask(null);
      if (!session && tab.href) router.push(hrefWithOpenNonce(tab.href));
      return;
    }
    setPendingTask(null);
    if (!tab.tool) return;
    const session = sessionForTab(tab, openSessions);
    if (session && session.focused) {
      setPendingTool(null);
      tools.setComputerTab(tab.tool);
      return;
    }
    if (session) {
      setPendingTool({ tab, tool: tab.tool });
      workspaceCommands().focusSession(session.paneId, session.id, {
        replaceWorkspace: true,
      });
      if (tab.href) router.replace(hrefWithOpenNonce(tab.href));
      return;
    }
    if (tab.sessionId || tab.threadId) {
      setPendingTool({ tab, tool: tab.tool });
      if (tab.href) router.replace(hrefWithOpenNonce(tab.href));
      return;
    }
    setPendingTool(null);
    tools.setComputerTab(tab.tool);
  };

  const openNewTask = () => {
    const tab = emptyTaskTab(currentProjectId);
    draftPromotionRef.current = draftPromotion(currentProjectId, openSessions);
    setLauncherOpen(false);
    setPendingTool(null);
    setPendingTask(null);
    setState((current) => ({
      ...current,
      tabs: upsertTab(current.tabs, tab),
      activeId: tab.id,
      closedTabIds: current.closedTabIds.filter((id) => id !== tab.id),
    }));
    tools.setComputerOpen(false);
    router.push(hrefWithOpenNonce(tab.href ?? "/agent?new=1&replace=1"));
  };

  const closeTab = (tabId: string) => {
    const index = orderedTabs.findIndex((tab) => tab.id === tabId);
    const closing = orderedTabs[index];
    if (!closing) return;
    if (closing.kind === "task") return;
    if (closing.tool) tools.closeComputerTab(closing.tool);
    const remaining = orderedTabs.filter((tab) => tab.id !== tabId);
    const nextActive =
      activeTabId === tabId
        ? (remaining[Math.min(index, remaining.length - 1)] ?? remaining.at(-1) ?? null)
        : null;
    const fallback = navigationTask;
    setState((current) => {
      let tabs = current.tabs.filter((tab) => tab.id !== tabId);
      let activeId =
        current.activeId === tabId ? (nextActive?.id ?? fallback.id) : current.activeId;
      if (tabs.length === 0) tabs = [fallback];
      if (!tabs.some((tab) => tab.id === activeId)) activeId = tabs[0]?.id ?? null;
      return {
        tabs,
        activeId,
        closedTabIds: [...new Set([...current.closedTabIds, closing.id])],
      };
    });
    if (pendingTool?.tab.id === closing.id) setPendingTool(null);
    const target = closeFocusTarget(activeTabId, tabId, nextActive, fallback);
    if (target) {
      activateTab(target);
      requestAnimationFrame(() => tabElementsRef.current.get(target.id)?.focus());
    } else {
      requestAnimationFrame(() => {
        const active = activeTabId ? tabElementsRef.current.get(activeTabId) : null;
        active?.focus();
      });
    }
  };

  const activateAtIndex = (index: number) => {
    const tab = orderedTabs[index];
    if (tab) activateTab(tab);
  };

  const cycleTab = (direction: -1 | 1) => {
    if (orderedTabs.length < 2) return;
    const activeIndex = Math.max(
      0,
      orderedTabs.findIndex((tab) => tab.id === activeTabId),
    );
    const nextIndex = (activeIndex + direction + orderedTabs.length) % orderedTabs.length;
    activateAtIndex(nextIndex);
  };

  const focusTabAtIndex = (index: number) => {
    if (orderedTabs.length === 0) return;
    const boundedIndex = (index + orderedTabs.length) % orderedTabs.length;
    const tab = orderedTabs[boundedIndex];
    if (!tab) return;
    activateTab(tab);
    tabElementsRef.current.get(tab.id)?.focus();
  };

  useMountSubscription(() => {
    const fallback = initialState(currentProjectId);
    setState(loadWorkbenchState(fallback));
    setHydrated(true);
  }, []);

  useMountSubscription(() => {
    let cancelled = false;
    const refresh = () => {
      void loadAggregatedSessionsOptional(null).then((sessions) => {
        if (cancelled || !sessions) return;
        setSessionCatalog((current) => ({
          sessions: new Map(sessions.map((session) => [session.id, session])),
          version: current.version + 1,
        }));
      });
    };
    refresh();
    window.addEventListener(SESSIONS_CHANGED_EVENT, refresh);
    return () => {
      cancelled = true;
      window.removeEventListener(SESSIONS_CHANGED_EVENT, refresh);
    };
  }, []);

  useMountSubscription(() => {
    if (hydrated) writeWorkbenchState(state);
  }, [hydrated, state]);

  useMountSubscription(() => {
    const navigationChanged = lastAgentNavigationRef.current !== agentNavigationKey;
    lastAgentNavigationRef.current = agentNavigationKey;
    draftPromotionRef.current = trackDraftPromotion(
      draftPromotionRef.current,
      wantsNewTask,
      currentProjectId,
      openSessions,
    );
    const pendingDraft = draftPromotionRef.current;
    const shouldPromoteDraft = canPromoteDraft(pendingDraft, focusedSession, state.tabs);
    const nextTask = navigationTask;
    setState((current) => {
      const idRemap = new Map<string, string>();
      let sourceTabs = current.tabs;
      if (shouldPromoteDraft && focusedSession) {
        const promoted = promoteDraftTabs(sourceTabs, focusedSession);
        sourceTabs = promoted.tabs;
        for (const [from, to] of promoted.idRemap) idRemap.set(from, to);
      }
      let tabs = sourceTabs.map((tab) => {
        const session = sessionForTab(tab, openSessions);
        if (!session) return tab;
        const refreshed = tab.kind === "task" ? taskTab(session) : toolTab(tab.tool!, session);
        if (refreshed.id !== tab.id) idRemap.set(tab.id, refreshed.id);
        return refreshed;
      });
      tabs = validWorkbenchTabs(
        tabs,
        openSessions,
        catalogSessionIds(sessionCatalog.sessions),
        new Set(projects.projects.map((project) => project.id)),
        projects.loaded,
      );
      let closedTabIds = current.closedTabIds.map((id) => idRemap.get(id) ?? id);
      let activeId = current.activeId ? (idRemap.get(current.activeId) ?? current.activeId) : null;
      tabs = dedupeTabs(tabs);
      for (const session of openSessions) {
        const tab = taskTab(session);
        if (!closedTabIds.includes(tab.id)) tabs = upsertTab(tabs, tab);
      }
      if (navigationChanged || !tabs.some((tab) => tab.id === nextTask.id)) {
        closedTabIds = closedTabIds.filter((id) => id !== nextTask.id);
        tabs = upsertTab(tabs, nextTask);
        if (navigationChanged && !pendingTool) activeId = nextTask.id;
      }
      if (!tabs.some((tab) => tab.id === activeId)) {
        activeId = tabs.at(-1)?.id ?? nextTask.id;
      }
      return {
        tabs,
        activeId,
        closedTabIds: [...new Set(closedTabIds)],
      };
    });
    if (shouldPromoteDraft) draftPromotionRef.current = null;
  }, [sessionSyncKey]);

  useMountSubscription(() => {
    const focusedSessionKey = focusedSession ? sessionIdentity(focusedSession) : null;
    if (computer.sessionKey !== focusedSessionKey) return;
    const scope = focusedSession ? taskTab(focusedSession) : emptyTaskTab(currentProjectId);
    setState((current) => {
      let tabs = current.tabs;
      let closedTabIds = current.closedTabIds;
      for (const tool of computer.tabs) {
        const tab = toolTab(tool, scope);
        const explicitlyOpened = computer.open && computer.tab === tool;
        if (tool === "status" && !explicitlyOpened && !tabs.some((item) => item.id === tab.id)) {
          continue;
        }
        if (closedTabIds.includes(tab.id) && !explicitlyOpened) continue;
        if (explicitlyOpened) closedTabIds = closedTabIds.filter((id) => id !== tab.id);
        tabs = upsertTab(tabs, tab);
      }
      const activeId =
        computer.open && !pendingTask ? toolTab(computer.tab, scope).id : current.activeId;
      return { tabs, activeId, closedTabIds };
    });
  }, [computerSyncKey]);

  useMountSubscription(() => {
    if (!pendingTask || !focusedSession || !tabMatchesSession(pendingTask, focusedSession)) return;
    const frame = requestAnimationFrame(() => {
      tools.setComputerOpen(false);
      setState((current) => ({
        ...current,
        tabs: upsertTab(current.tabs, pendingTask),
        activeId: pendingTask.id,
        closedTabIds: current.closedTabIds.filter((id) => id !== pendingTask.id),
      }));
      setPendingTask(null);
    });
    return () => cancelAnimationFrame(frame);
  }, [focusedSession?.id, focusedSession?.threadId, pendingTask?.id, tools]);

  useMountSubscription(() => {
    if (!pendingTool || !focusedSession || !tabMatchesSession(pendingTool.tab, focusedSession)) {
      return;
    }
    let secondFrame = 0;
    const firstFrame = window.requestAnimationFrame(() => {
      secondFrame = window.requestAnimationFrame(() => {
        tools.setComputerTab(pendingTool.tool);
        setPendingTool(null);
      });
    });
    return () => {
      window.cancelAnimationFrame(firstFrame);
      if (secondFrame) window.cancelAnimationFrame(secondFrame);
    };
  }, [focusedSession?.id, focusedSession?.threadId, pendingTool?.tab.id, pendingTool?.tool, tools]);

  useMountSubscription(() => {
    const wasOpen = previousComputerOpenRef.current;
    previousComputerOpenRef.current = computer.open;
    if (!wasOpen || computer.open) return;
    const active = orderedTabs.find((tab) => tab.id === activeTabId);
    if (active?.kind !== "tool") return;
    activateTab(focusedSession ? taskTab(focusedSession) : emptyTaskTab(currentProjectId));
  }, [
    computer.open,
    currentProjectId,
    focusedSession?.id,
    focusedSession?.threadId,
    activeTabId,
    orderedTabs,
  ]);

  useMountSubscription(() => {
    const element = activeTabId ? tabElementsRef.current.get(activeTabId) : null;
    element?.scrollIntoView({ block: "nearest", inline: "nearest" });
  }, [activeTabId]);

  useMountSubscription(() => {
    if (!launcherOpen) return;
    const frame = requestAnimationFrame(() => {
      launcherRef.current?.querySelector<HTMLElement>('input, [role="menuitem"]')?.focus();
    });
    const onPointerDown = (event: PointerEvent) => {
      if (!launcherRef.current?.contains(event.target as Node)) setLauncherOpen(false);
    };
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") setLauncherOpen(false);
    };
    window.addEventListener("pointerdown", onPointerDown);
    window.addEventListener("keydown", onKeyDown);
    return () => {
      cancelAnimationFrame(frame);
      window.removeEventListener("pointerdown", onPointerDown);
      window.removeEventListener("keydown", onKeyDown);
    };
  }, [launcherOpen]);

  useMountSubscription(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (!(event.metaKey || event.ctrlKey) || isEditableTarget(event.target)) return;
      const key = event.key.toLowerCase();
      if (!event.shiftKey && /^[1-9]$/.test(key)) {
        event.preventDefault();
        activateAtIndex(Number(key) - 1);
        return;
      }
      if (!event.shiftKey && key === "w") {
        event.preventDefault();
        const active = orderedTabs.find((tab) => tab.id === activeTabId);
        if (active?.kind === "tool") closeTab(active.id);
        return;
      }
      if (!event.shiftKey && (key === "t" || key === "n")) {
        event.preventDefault();
        openNewTask();
        return;
      }
      if (event.shiftKey && (event.code === "BracketLeft" || event.key === "{")) {
        event.preventDefault();
        cycleTab(-1);
      }
      if (event.shiftKey && (event.code === "BracketRight" || event.key === "}")) {
        event.preventDefault();
        cycleTab(1);
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [shortcutSyncKey]);

  const dropTab = (event: DragEvent<HTMLDivElement>, targetId: string) => {
    event.preventDefault();
    const sourceId = draggedTabRef.current;
    draggedTabRef.current = null;
    if (!sourceId) return;
    setState((current) => ({
      ...current,
      tabs: reorderTabs(current.tabs, sourceId, targetId),
    }));
  };

  const activeScope = navigationTask;
  const projectName = projectNames.get(activeScope.projectId ?? "workspace") ?? "Workspace";

  return (
    <header className="workbench-tab-strip relative flex h-[var(--workbench-tab-height)] shrink-0 border-b border-(--border) bg-(--color-header)">
      {!sidebarExpanded ? (
        <button
          type="button"
          data-ui-control="compact"
          onClick={() => setSidebarExpanded(true)}
          className="hidden h-full w-8 shrink-0 items-center justify-center border-r border-(--border) text-(--dim) transition-colors duration-[var(--motion-fast)] hover:bg-(--hover) hover:text-(--fg) md:flex"
          aria-label="Expand sidebar"
          title="Expand sidebar"
        >
          <PanelLeftHollow className="h-3.5 w-3.5" strokeWidth={1.75} />
        </button>
      ) : null}
      <button
        type="button"
        data-ui-control="compact"
        onClick={() => setMobileNavOpen(true)}
        className="flex h-full w-8 shrink-0 items-center justify-center border-r border-(--border) text-(--dim) transition-colors hover:bg-(--hover) hover:text-(--fg) md:hidden"
        aria-label="Open navigation menu"
        aria-controls="mobile-navigation-drawer"
      >
        <Menu className="h-3.5 w-3.5" />
      </button>
      <WorkbenchProjectTabList
        projectName={projectName}
        threadTitle={activeScope.groupTitle}
        orderedTabs={orderedTabs}
        activeId={activeTabId}
        onActivate={activateTab}
        onClose={closeTab}
        onFocusTab={focusTabAtIndex}
        onDragStart={(tabId) => {
          draggedTabRef.current = tabId;
        }}
        onDrop={dropTab}
        register={(tabId, element) => {
          if (element) tabElementsRef.current.set(tabId, element);
          else tabElementsRef.current.delete(tabId);
        }}
      />
      <div
        ref={launcherRef}
        className="relative flex shrink-0 items-center border-l border-(--border)"
      >
        <button
          type="button"
          data-ui-control="compact"
          onClick={() => setLauncherOpen((open) => !open)}
          className="flex h-full w-8 items-center justify-center text-(--dim) transition-colors duration-[var(--motion-fast)] hover:bg-(--hover) hover:text-(--fg)"
          aria-label="Open thread tab"
          title="Open thread tab"
          aria-expanded={launcherOpen}
          aria-haspopup="menu"
        >
          <Plus className="h-3.5 w-3.5" strokeWidth={1.8} />
        </button>
        {launcherOpen ? (
          <WorkbenchLauncher
            onOpenTool={(tool) => activateTab(toolTab(tool, activeScope))}
            onDismiss={() => {
              setLauncherOpen(false);
              launcherRef.current?.querySelector("button")?.focus();
            }}
          />
        ) : null}
      </div>
    </header>
  );
}
