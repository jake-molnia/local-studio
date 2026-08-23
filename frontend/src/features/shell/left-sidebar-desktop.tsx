"use client";

import Link from "next/link";
import { ProfileFooter } from "@/features/shell/profile-footer";
import { type MouseEvent as ReactMouseEvent } from "react";
import {
  BellIcon,
  ChevronLeft,
  ChevronRight,
  SearchIcon,
  NewTaskIcon,
  SettingsIcon,
  PanelLeftHollow,
  PanelLeftFilled,
} from "@/ui/icon-registry";
import type { NavView, ProjectsNavSectionComponent } from "@/features/shell/left-sidebar-lazy";
import {
  NavItemDesktop,
  NavActionDesktop,
  ProjectsNavPlaceholder,
  primaryTabs,
  studioTabs,
  customizeTab,
  isRouteActive,
} from "@/features/shell/left-sidebar-nav";

const HISTORY_STEPPER_CLASS =
  "flex h-6 w-6 items-center justify-center rounded-[4px] text-(--hl2) opacity-0 transition-[opacity,color,background-color] duration-[var(--motion-fast)] hover:bg-(--hover) hover:text-(--fg) focus-visible:opacity-100 group-hover/sidebar:opacity-70";

export function DesktopSidebar({
  pathname,
  isExpanded,
  width,
  resizing,
  projectsNavReady,
  ProjectsNavSection,
  onStartResize,
  onRevealProjectsNav,
  onSetPinnedOpen,
  onOpenSearch,
  navView,
  onToggleNavView,
  runningSessions,
  finishedSessions,
  onNewTask,
}: {
  pathname: string;
  isExpanded: boolean;
  width: number;
  resizing: boolean;
  projectsNavReady: boolean;
  ProjectsNavSection: ProjectsNavSectionComponent | null;
  onStartResize: (event: ReactMouseEvent<HTMLDivElement>) => void;
  onRevealProjectsNav: () => void;
  onSetPinnedOpen: (open: boolean) => void;
  onOpenSearch: () => void;
  navView: NavView;
  onToggleNavView: () => void;
  runningSessions: number;
  finishedSessions: number;
  onNewTask: () => void;
}) {
  return (
    <aside
      onPointerEnter={onRevealProjectsNav}
      onFocusCapture={onRevealProjectsNav}
      className={`group/sidebar relative hidden md:flex sticky top-0 h-[100dvh] border-r border-(--border) bg-(--sidebar-bg) flex-col shrink-0 z-40 overflow-hidden ${
        resizing
          ? ""
          : "transition-[width] duration-[var(--motion-fast)] ease-[var(--ease-standard)]"
      }`}
      style={{
        width: isExpanded ? `${width}px` : 44,
      }}
    >
      {isExpanded ? (
        <div
          role="separator"
          aria-orientation="vertical"
          aria-label="Resize sidebar"
          title="Resize sidebar"
          onMouseDown={onStartResize}
          className={`absolute right-0 top-0 z-[60] h-full w-2 cursor-col-resize transition-colors ${
            resizing ? "bg-(--fg)/10" : "hover:bg-(--fg)/8"
          }`}
        />
      ) : null}
      {!isExpanded ? (
        <div className="flex h-[var(--h-toolbar)] shrink-0 items-center justify-center">
          <button
            onClick={() => onSetPinnedOpen(true)}
            className="flex h-7 w-7 items-center justify-center rounded-md text-(--hl2) transition-colors hover:bg-(--hover) hover:text-(--fg)"
            title="Expand sidebar"
            aria-label="Expand sidebar"
          >
            <PanelLeftHollow className="h-3.5 w-3.5" strokeWidth={1.75} />
          </button>
        </div>
      ) : null}
      <div
        className={`flex min-h-0 flex-1 flex-col overflow-hidden ${
          isExpanded ? "opacity-100" : "pointer-events-none opacity-0"
        }`}
      >
        {isExpanded ? (
          <>
            <div className="sticky top-0 z-50 flex h-[var(--h-toolbar)] shrink-0 items-center gap-0.5 border-b border-(--border)/35 bg-(--sidebar-bg) px-1.5">
              <button
                onClick={() => onSetPinnedOpen(false)}
                className="flex h-7 w-7 items-center justify-center rounded-md text-(--hl2) transition-colors hover:bg-(--hover) hover:text-(--fg)"
                title="Collapse sidebar"
                aria-label="Collapse sidebar"
              >
                <PanelLeftFilled className="h-3 w-3" strokeWidth={1.75} />
              </button>
              <div className="min-w-0 flex-1" />
              <SessionStatus running={runningSessions} finished={finishedSessions} />
              <button
                onClick={() => window.history.back()}
                className={HISTORY_STEPPER_CLASS}
                title="Go back"
                aria-label="Go back"
              >
                <ChevronLeft className="h-3 w-3" strokeWidth={1.75} />
              </button>
              <button
                onClick={() => window.history.forward()}
                className={HISTORY_STEPPER_CLASS}
                title="Go forward"
                aria-label="Go forward"
              >
                <ChevronRight className="h-3 w-3" strokeWidth={1.75} />
              </button>
              <button
                onClick={onToggleNavView}
                aria-pressed={navView === "notifications"}
                className="flex h-6 w-6 items-center justify-center rounded-[4px] text-(--hl2) opacity-0 transition-[opacity,color,background-color] duration-[var(--motion-fast)] hover:bg-(--hover) hover:text-(--fg) focus-visible:opacity-100 group-hover/sidebar:opacity-70 aria-pressed:opacity-100 aria-pressed:text-(--fg)"
                title={navView === "notifications" ? "Show projects" : "Show notifications"}
                aria-label={navView === "notifications" ? "Show projects" : "Show notifications"}
              >
                <BellIcon className="h-3.5 w-3.5" />
              </button>
            </div>

            <nav className="sidebar-scroller flex min-h-0 flex-1 flex-col overflow-x-hidden overflow-y-auto px-[var(--sidebar-padding-x)] py-1 [contain:layout_paint]">
              <div className="flex shrink-0 flex-col gap-[var(--sidebar-row-gap)]">
                <Link
                  href="/agent?new=1&replace=1"
                  prefetch={false}
                  onClick={(event) => {
                    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
                    event.preventDefault();
                    onNewTask();
                  }}
                  className={`group flex h-[var(--sidebar-row-height)] shrink-0 items-center gap-2 rounded-[var(--sidebar-row-radius)] px-2 text-(--fg)/90 transition-colors hover:bg-(--hover) hover:text-(--fg) ${
                    pathname === "/agent" ? "bg-(--active)" : ""
                  }`}
                  title="New task"
                >
                  <NewTaskIcon className="h-3.5 w-3.5 shrink-0 opacity-80" />
                  <span className="flex-1 truncate text-left text-[length:var(--fs-xs)] font-medium">
                    New task
                  </span>
                  <kbd className="rounded-[3px] border border-(--border) px-1 text-[10px] leading-4 text-(--dim)">
                    ⌘N
                  </kbd>
                </Link>
                <NavActionDesktop
                  label="Search"
                  Icon={SearchIcon}
                  shortcut="⌘K"
                  onClick={onOpenSearch}
                />
                {primaryTabs.map((tab) => (
                  <NavItemDesktop
                    key={tab.href}
                    href={tab.href}
                    label={tab.label}
                    Icon={tab.icon}
                    active={isRouteActive(pathname, tab.href)}
                  />
                ))}
                <NavItemDesktop
                  href={customizeTab.href}
                  label={customizeTab.label}
                  Icon={customizeTab.icon}
                  active={isRouteActive(pathname, customizeTab.href)}
                />
              </div>
              {projectsNavReady ? (
                ProjectsNavSection ? (
                  <ProjectsNavSection expanded={isExpanded} view={navView} />
                ) : (
                  <ProjectsNavPlaceholder />
                )
              ) : null}
              <details
                className="group/studio mt-2 shrink-0 border-t border-(--border)/35 pt-1"
                open={studioTabs.some((tab) => isRouteActive(pathname, tab.href)) || undefined}
              >
                <summary className="flex h-[var(--sidebar-row-height)] cursor-pointer list-none items-center gap-1 rounded-[var(--sidebar-row-radius)] px-2 text-[10px] font-medium text-(--dim)/60 transition-colors hover:bg-(--hover) hover:text-(--dim) [&::-webkit-details-marker]:hidden">
                  <ChevronRight className="h-2.5 w-2.5 transition-transform duration-[var(--motion-fast)] group-open/studio:rotate-90" />
                  Studio
                </summary>
                <div className="flex flex-col gap-[var(--sidebar-row-gap)]">
                  {studioTabs.map((tab) => (
                    <NavItemDesktop
                      key={tab.href}
                      href={tab.href}
                      label={tab.label}
                      Icon={tab.icon}
                      active={isRouteActive(pathname, tab.href)}
                    />
                  ))}
                </div>
              </details>
            </nav>

            <div className="shrink-0 bg-(--sidebar-bg) px-[var(--sidebar-padding-x)] pb-2 pt-1">
              <ProfileFooter settingsActive={isRouteActive(pathname, "/settings")} />
            </div>
          </>
        ) : null}
      </div>
    </aside>
  );
}

function SessionStatus({ running, finished }: { running: number; finished: number }) {
  if (running > 0) {
    return (
      <span
        className="flex shrink-0 items-center gap-1 rounded-md px-1 text-[length:var(--fs-xs)] tabular-nums text-(--hl2) opacity-0 transition-opacity group-hover/sidebar:opacity-70"
        title={`${running} ${running === 1 ? "session is" : "sessions are"} running`}
      >
        <span className="h-1.5 w-1.5 animate-pulse rounded-full bg-(--ok)" aria-hidden />
        {running}
      </span>
    );
  }
  if (finished > 0) {
    return (
      <span
        className="flex shrink-0 items-center gap-1 rounded-md px-1 text-[length:var(--fs-xs)] tabular-nums text-(--hl2) opacity-0 transition-opacity group-hover/sidebar:opacity-70"
        title={`${finished} ${finished === 1 ? "session" : "sessions"} finished while you were away`}
      >
        <span className="h-1.5 w-1.5 rounded-full bg-(--ok)/60" aria-hidden />
        {finished}
      </span>
    );
  }
  return null;
}
