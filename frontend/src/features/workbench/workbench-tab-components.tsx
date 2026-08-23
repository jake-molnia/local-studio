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
import { handleLauncherKeyDown, projectInitial } from "@/features/workbench/workbench-tab-helpers";
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
  projectName,
  threadTitle,
  orderedTabs,
  activeId,
  onActivate,
  onClose,
  onFocusTab,
  onDragStart,
  onDrop,
  register,
}: {
  projectName: string;
  threadTitle: string;
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
      aria-label={`${projectName}, ${threadTitle} tabs`}
      className="flex min-w-0 flex-1 items-stretch gap-0 overflow-x-auto overflow-y-hidden px-1 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden"
    >
      <div
        role="presentation"
        className="flex h-full min-w-0 shrink-0 items-center gap-1.5 border-r border-(--border)/70 pr-2"
        title={`${projectName} · ${threadTitle}`}
      >
        <span className="flex h-4 w-4 shrink-0 items-center justify-center rounded-[3px] border border-(--border)/80 bg-(--fg)/4 text-(--hl2)">
          <span className="text-[9px] font-semibold leading-none">
            {projectInitial(projectName)}
          </span>
        </span>
        <span className="flex max-w-[170px] flex-col truncate leading-tight">
          <span className="truncate text-[10px] font-medium text-(--fg)">{projectName}</span>
          <span className="truncate text-[9px] text-(--dim)">{threadTitle}</span>
        </span>
      </div>
      {orderedTabs.map((tab, index) => (
        <WorkbenchTabButton
          key={tab.id}
          tab={tab}
          active={tab.id === activeId}
          ariaLabel={`${projectName}, ${threadTitle}, ${tab.title}`}
          shortcut={index < 9 ? `⌘${index + 1}` : undefined}
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
      className={`workbench-tab group relative flex h-full shrink-0 items-center gap-1 border-r border-t px-2 text-left text-[11px] transition-colors duration-[var(--motion-fast)] ${
        tab.kind === "task" ? "w-[104px] max-w-[104px]" : "w-[100px] max-w-[100px]"
      } ${
        active
          ? "border-(--border) border-b-(--agent-bg) bg-(--agent-bg) text-(--fg)"
          : "border-(--border)/35 bg-(--color-header) text-(--dim) hover:bg-(--hover) hover:text-(--fg)"
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
          className={`relative flex h-4 w-4 shrink-0 items-center justify-center transition-colors duration-[var(--motion-fast)] ${
            active ? "text-(--fg)" : "text-(--hl2)"
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
          className="flex h-4 w-4 shrink-0 items-center justify-center rounded-[3px] text-(--dim) opacity-0 transition-[background-color,color,opacity] duration-[var(--motion-fast)] group-hover:opacity-75 focus-visible:opacity-75 hover:bg-(--fg)/8 hover:text-(--fg)"
        >
          <CloseIcon className="h-2.5 w-2.5" />
        </button>
      ) : null}
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
