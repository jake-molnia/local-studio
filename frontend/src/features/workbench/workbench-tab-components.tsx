import type { ComponentType, DragEvent, KeyboardEvent as ReactKeyboardEvent } from "react";
import {
  Activity,
  ChatIcon,
  CloseIcon,
  FolderTree,
  GitBranch,
  Globe2,
  NewTaskIcon,
  TerminalSquare,
  Wrench,
} from "@/ui/icon-registry";
import { isWorkingStatus } from "@/features/agent/runtime/session-status";
import type { ComputerTab } from "@/features/agent/tools/types";
import { COMPUTER_TAB_TITLES, type WorkbenchTab } from "@/features/workbench/model";
import {
  handleLauncherKeyDown,
  projectInitial,
  type ProjectTabGroup,
} from "@/features/workbench/workbench-tab-helpers";
import { POPOVER_SURFACE_CLASS } from "@/ui/popover";

type WorkbenchIcon = ComponentType<{ className?: string; strokeWidth?: number }>;

const TOOL_ICONS: Record<ComputerTab, WorkbenchIcon> = {
  status: Activity,
  tools: Wrench,
  "side-chat": ChatIcon,
  browser: Globe2,
  files: FolderTree,
  diff: GitBranch,
  terminal: TerminalSquare,
};

function tabIcon(tab: WorkbenchTab): WorkbenchIcon {
  return tab.kind === "task" ? ChatIcon : TOOL_ICONS[tab.tool ?? "tools"];
}

export function WorkbenchProjectTabList({
  projectGroups,
  orderedTabs,
  activeId,
  onActivate,
  onClose,
  onFocusTab,
  onDragStart,
  onDrop,
  register,
}: {
  projectGroups: readonly ProjectTabGroup[];
  orderedTabs: readonly WorkbenchTab[];
  activeId: string | null;
  onActivate: (tab: WorkbenchTab) => void;
  onClose: (tabId: string) => void;
  onFocusTab: (index: number) => void;
  onDragStart: (tabId: string) => void;
  onDrop: (event: DragEvent<HTMLDivElement>, targetId: string) => void;
  register: (tabId: string, element: HTMLButtonElement | null) => void;
}) {
  return (
    <div
      role="tablist"
      aria-label="Project thread tabs"
      className="flex min-w-0 flex-1 items-stretch overflow-x-auto overflow-y-hidden [scrollbar-width:none] [&::-webkit-scrollbar]:hidden"
    >
      {projectGroups.map((project) => (
        <div
          key={project.id}
          role="presentation"
          className="workbench-project-tabs flex h-full shrink-0 items-stretch border-r border-(--border)"
        >
          <div
            aria-label={`Project ${project.name}`}
            className="flex h-full max-w-[76px] shrink-0 items-center gap-1 border-r border-(--border)/80 bg-(--sidebar-bg) px-1.5 text-[10px] font-medium text-(--dim)"
            title={project.name}
          >
            <span className="flex h-4 w-4 shrink-0 items-center justify-center rounded-[3px] border border-(--border)/80 bg-(--fg)/4 text-(--hl2)">
              <span className="text-[9px] font-semibold leading-none">
                {projectInitial(project.name)}
              </span>
            </span>
            <span className="truncate">{project.name}</span>
          </div>
          {project.threads.map((thread) => (
            <div
              key={thread.id}
              role="presentation"
              data-thread-group={thread.id}
              className="workbench-thread-tabs flex h-full shrink-0 items-stretch border-r border-(--border)/70 last:border-r-0"
              title={`${project.name} · ${thread.title}`}
            >
              <div className="flex h-full w-[84px] shrink-0 items-center border-r border-(--border)/55 px-1.5 text-[10px] text-(--dim)/80">
                <span className="truncate">{thread.title}</span>
              </div>
              {thread.tabs.map((tab) => {
                const index = orderedTabs.findIndex((candidate) => candidate.id === tab.id);
                return (
                  <WorkbenchTabButton
                    key={tab.id}
                    tab={tab}
                    active={tab.id === activeId}
                    ariaLabel={`${project.name}, ${thread.title}, ${tab.title}`}
                    shortcut={index >= 0 && index < 9 ? `⌘${index + 1}` : undefined}
                    onActivate={() => onActivate(tab)}
                    onClose={() => onClose(tab.id)}
                    onKeyDown={(event) => {
                      if (event.key === "ArrowLeft") {
                        event.preventDefault();
                        onFocusTab(index - 1);
                      } else if (event.key === "ArrowRight") {
                        event.preventDefault();
                        onFocusTab(index + 1);
                      } else if (event.key === "Home") {
                        event.preventDefault();
                        onFocusTab(0);
                      } else if (event.key === "End") {
                        event.preventDefault();
                        onFocusTab(orderedTabs.length - 1);
                      } else if (event.key === "Delete" || event.key === "Backspace") {
                        event.preventDefault();
                        onClose(tab.id);
                      }
                    }}
                    onDragStart={() => onDragStart(tab.id)}
                    onDrop={(event) => onDrop(event, tab.id)}
                    register={(element) => register(tab.id, element)}
                  />
                );
              })}
            </div>
          ))}
        </div>
      ))}
    </div>
  );
}

export function WorkbenchTabButton({
  tab,
  active,
  ariaLabel,
  shortcut,
  onActivate,
  onClose,
  onKeyDown,
  onDragStart,
  onDrop,
  register,
}: {
  tab: WorkbenchTab;
  active: boolean;
  ariaLabel: string;
  shortcut?: string;
  onActivate: () => void;
  onClose: () => void;
  onKeyDown: (event: ReactKeyboardEvent<HTMLButtonElement>) => void;
  onDragStart: () => void;
  onDrop: (event: DragEvent<HTMLDivElement>) => void;
  register: (element: HTMLButtonElement | null) => void;
}) {
  const Icon = tabIcon(tab);
  const working = tab.kind === "task" && Boolean(tab.status && isWorkingStatus(tab.status));
  return (
    <div
      draggable={tab.kind === "tool"}
      onDragStart={onDragStart}
      onDragOver={(event) => event.preventDefault()}
      onDrop={onDrop}
      className={`workbench-tab group relative flex h-full shrink-0 items-center gap-1 border-r border-(--border)/65 px-1.5 text-left text-[11px] transition-[background-color,color] duration-[var(--motion-fast)] last:border-r-0 ${
        tab.kind === "task" ? "w-[144px] max-w-[184px]" : "w-[92px] max-w-[124px]"
      } ${
        active
          ? "bg-(--active) text-(--fg)"
          : "bg-(--color-header) text-(--dim) hover:bg-(--hover) hover:text-(--fg)"
      }`}
    >
      <button
        ref={register}
        type="button"
        role="tab"
        aria-selected={active}
        aria-label={ariaLabel}
        aria-controls="workbench-active-surface"
        id={active ? "workbench-active-tab" : undefined}
        tabIndex={active ? 0 : -1}
        onClick={onActivate}
        onKeyDown={onKeyDown}
        onAuxClick={(event) => {
          if (event.button === 1) onClose();
        }}
        title={shortcut ? `${tab.title} (${shortcut})` : tab.title}
        className="flex h-full min-w-0 flex-1 items-center gap-1 text-left outline-none"
      >
        <span
          className={`relative flex h-4 w-4 shrink-0 items-center justify-center rounded-[3px] border transition-colors duration-[var(--motion-fast)] ${
            active
              ? "border-(--border-heavy) bg-(--fg)/7 text-(--fg)"
              : "border-(--border)/70 bg-(--fg)/3 text-(--hl2)"
          }`}
        >
          <Icon
            className="h-[var(--workbench-tab-icon-size)] w-[var(--workbench-tab-icon-size)] opacity-90"
            strokeWidth={1.65}
          />
          {working ? (
            <span className="absolute -bottom-px -right-px h-1.5 w-1.5 rounded-full bg-(--accent) ring-2 ring-(--color-header)" />
          ) : null}
        </span>
        <span className="min-w-0 flex-1 truncate">{tab.title}</span>
      </button>
      {tab.kind === "tool" ? (
        <button
          type="button"
          tabIndex={active ? 0 : -1}
          aria-label={`Close ${tab.title}`}
          onClick={(event) => {
            event.stopPropagation();
            onClose();
          }}
          className={`flex h-4 w-4 shrink-0 items-center justify-center rounded-[3px] text-(--dim) transition-[background-color,color,opacity] duration-[var(--motion-fast)] hover:bg-(--fg)/8 hover:text-(--fg) ${
            active ? "opacity-60" : "opacity-0 group-hover:opacity-65 focus-visible:opacity-75"
          }`}
        >
          <CloseIcon className="h-2.5 w-2.5" />
        </button>
      ) : null}
      {active ? <span className="absolute inset-x-0 top-0 h-px bg-(--accent)/45" /> : null}
    </div>
  );
}

export function WorkbenchLauncher({
  threadTitle,
  onNewTask,
  onOpenTool,
  onDismiss,
}: {
  threadTitle: string;
  onNewTask: () => void;
  onOpenTool: (tool: ComputerTab) => void;
  onDismiss: () => void;
}) {
  return (
    <div
      className={`absolute right-1 top-[calc(100%+4px)] z-[180] w-52 p-1 ${POPOVER_SURFACE_CLASS}`}
      role="menu"
      aria-label="Open thread tab"
      onKeyDown={(event) => handleLauncherKeyDown(event, onDismiss)}
    >
      <div className="truncate px-2 pb-1 pt-0.5 text-[10px] font-medium text-(--dim)">
        {threadTitle}
      </div>
      <LauncherItem icon={NewTaskIcon} label="New task" shortcut="⌘T" onClick={onNewTask} />
      <div className="my-1 h-px bg-(--border)" />
      <div className="px-2 pb-1 pt-0.5 text-[10px] font-medium text-(--dim)">Local tools</div>
      <LauncherItem
        icon={ChatIcon}
        label={COMPUTER_TAB_TITLES["side-chat"]}
        onClick={() => onOpenTool("side-chat")}
      />
      <LauncherItem
        icon={TerminalSquare}
        label={COMPUTER_TAB_TITLES.terminal}
        onClick={() => onOpenTool("terminal")}
      />
      <LauncherItem
        icon={Globe2}
        label={COMPUTER_TAB_TITLES.browser}
        onClick={() => onOpenTool("browser")}
      />
      <LauncherItem
        icon={FolderTree}
        label={COMPUTER_TAB_TITLES.files}
        onClick={() => onOpenTool("files")}
      />
      <LauncherItem
        icon={GitBranch}
        label={COMPUTER_TAB_TITLES.diff}
        onClick={() => onOpenTool("diff")}
      />
      <LauncherItem
        icon={Activity}
        label={COMPUTER_TAB_TITLES.status}
        onClick={() => onOpenTool("status")}
      />
      <LauncherItem
        icon={Wrench}
        label={COMPUTER_TAB_TITLES.tools}
        onClick={() => onOpenTool("tools")}
      />
    </div>
  );
}

function LauncherItem({
  icon: Icon,
  label,
  shortcut,
  onClick,
}: {
  icon: WorkbenchIcon;
  label: string;
  shortcut?: string;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      role="menuitem"
      onClick={onClick}
      className="flex h-6 w-full items-center gap-1.5 rounded-[var(--ui-radius-control)] px-1.5 text-left text-[length:var(--fs-xs)] text-(--fg)/90 transition-colors duration-[var(--motion-fast)] hover:bg-(--hover)"
    >
      <Icon className="h-3 w-3 shrink-0 text-(--dim)" strokeWidth={1.65} />
      <span className="min-w-0 flex-1 truncate">{label}</span>
      {shortcut ? <kbd className="text-[10px] text-(--dim)">{shortcut}</kbd> : null}
    </button>
  );
}
