import {
  useMemo,
  useState,
  type ComponentType,
  type DragEvent,
  type KeyboardEvent as ReactKeyboardEvent,
} from "react";
import {
  Activity,
  ChatIcon,
  CloseIcon,
  FolderTree,
  GitBranch,
  Globe2,
  TerminalSquare,
  Wrench,
} from "@/ui/icon-registry";
import { isWorkingStatus } from "@/features/agent/runtime/session-status";
import type { ComputerTab } from "@/features/agent/tools/types";
import { COMPUTER_TAB_TITLES, type WorkbenchTab } from "@/features/workbench/model";
import { handleLauncherKeyDown, projectInitial } from "@/features/workbench/workbench-tab-helpers";
import { POPOVER_SURFACE_CLASS } from "@/ui/popover";
import { cx } from "@/ui/utils";

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
  sidebarCollapsed,
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
  sidebarCollapsed?: boolean;
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
      className={`flex min-w-0 flex-1 items-stretch overflow-hidden ${sidebarCollapsed ? "md:pl-7" : ""}`}
    >
      <div
        className="workbench-project-context flex min-w-0 max-w-[220px] shrink-0 items-center gap-1.5 border-r border-(--border)/45 px-2.5"
        title={`${projectName} · ${threadTitle}`}
      >
        <span className="flex h-4 w-4 shrink-0 items-center justify-center rounded-[4px] bg-(--accent)/15 text-[9px] font-semibold leading-none text-(--accent)">
          {projectInitial(projectName)}
        </span>
        <span className="min-w-0 truncate text-[length:var(--fs-xs)] text-(--dim)">
          <span className="text-(--fg)/80">{projectName}</span>
          <span className="px-1 text-(--dim)/55">/</span>
          {threadTitle}
        </span>
      </div>
      <div
        role="tablist"
        aria-orientation="horizontal"
        aria-label={`${projectName}, ${threadTitle} tabs`}
        className="flex min-w-0 flex-1 items-end gap-0 overflow-x-auto overflow-y-hidden px-1 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden"
      >
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
      role="presentation"
      draggable={tab.kind === "tool"}
      onDragStart={onDragStart}
      onDragOver={(event) => event.preventDefault()}
      onDrop={onDrop}
      style={{
        flex: "0 1 clamp(var(--workbench-tab-min-width), 12vw, var(--workbench-tab-max-width))",
      }}
      className={`workbench-tab group/tab relative flex h-[30px] min-w-[var(--workbench-tab-min-width)] max-w-[var(--workbench-tab-max-width)] shrink-0 items-center self-end border-x border-y px-2 text-left text-[length:var(--fs-xs)] transition-[background-color,border-color,color,box-shadow] duration-[var(--motion-fast)] ${
        active
          ? "z-10 -mb-px rounded-t-[8px] border-(--border)/70 border-b-(--agent-bg) bg-(--agent-bg) text-(--fg) shadow-[0_-1px_0_color-mix(in_srgb,var(--border)_55%,transparent)]"
          : "rounded-t-[7px] border-transparent bg-transparent text-(--dim) hover:bg-(--hover) hover:text-(--fg)"
      } ${
        active
          ? ""
          : "after:absolute after:right-0 after:top-1/2 after:h-4 after:w-px after:-translate-y-1/2 after:bg-(--border)/45"
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
        className="flex h-full min-w-0 flex-1 items-center gap-1.5 text-left outline-none focus-visible:rounded-[4px] focus-visible:ring-1 focus-visible:ring-(--focus-ring) focus-visible:ring-offset-[-1px]"
      >
        <span
          className={`relative flex h-4 w-4 shrink-0 items-center justify-center transition-colors duration-[var(--motion-fast)] ${
            active ? "text-(--fg)" : "text-(--hl2)"
          }`}
        >
          <Icon className="h-3 w-3 opacity-90" strokeWidth={1.65} />
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
          className={cx(
            "flex h-4 w-4 shrink-0 items-center justify-center rounded-[4px] text-(--dim) opacity-0 transition-[background-color,color,opacity] duration-[var(--motion-fast)] group-hover/tab:opacity-80 focus-visible:opacity-100 focus-visible:bg-(--fg)/8 hover:bg-(--fg)/8 hover:text-(--fg)",
          )}
        >
          <CloseIcon className="h-2.5 w-2.5" />
        </button>
      ) : null}
    </div>
  );
}

export function WorkbenchLauncher({
  onOpenTool,
  onDismiss,
}: {
  onOpenTool: (tool: ComputerTab) => void;
  onDismiss: () => void;
}) {
  const [query, setQuery] = useState("");
  const entries = useMemo(
    () =>
      [
        ["side-chat", ChatIcon],
        ["terminal", TerminalSquare],
        ["browser", Globe2],
        ["files", FolderTree],
        ["diff", GitBranch],
        ["status", Activity],
        ["tools", Wrench],
      ] as const,
    [],
  );
  const normalized = query.trim().toLowerCase();
  const visible = entries.filter(([tool]) =>
    COMPUTER_TAB_TITLES[tool].toLowerCase().includes(normalized),
  );
  return (
    <div
      className={`absolute right-1 top-[calc(100%+4px)] z-[180] w-52 p-1 ${POPOVER_SURFACE_CLASS}`}
      role="menu"
      aria-label="Open tool tab"
      onKeyDown={(event) => handleLauncherKeyDown(event, onDismiss)}
    >
      <input
        type="search"
        value={query}
        onChange={(event) => setQuery(event.target.value)}
        placeholder="Search tools"
        aria-label="Search tools"
        className="mb-1 h-7 w-full rounded-[4px] bg-(--color-input) px-2 text-[length:var(--fs-xs)] text-(--fg) outline-none placeholder:text-(--dim) focus:ring-1 focus:ring-(--accent)/35"
      />
      {visible.length ? (
        visible.map(([tool, Icon]) => (
          <LauncherItem
            key={tool}
            icon={Icon}
            label={COMPUTER_TAB_TITLES[tool]}
            onClick={() => onOpenTool(tool)}
          />
        ))
      ) : (
        <div className="px-2 py-2 text-center text-[length:var(--fs-xs)] text-(--dim)">
          No matching tools
        </div>
      )}
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
      data-ui-control="compact"
      onClick={onClick}
      className="flex h-6 w-full items-center gap-1.5 rounded-[var(--ui-radius-control)] px-1.5 text-left text-[length:var(--fs-xs)] text-(--fg)/90 transition-colors duration-[var(--motion-fast)] hover:bg-(--hover)"
    >
      <Icon className="h-3 w-3 shrink-0 text-(--dim)" strokeWidth={1.65} />
      <span className="min-w-0 flex-1 truncate">{label}</span>
      {shortcut ? <kbd className="text-[10px] text-(--dim)">{shortcut}</kbd> : null}
    </button>
  );
}
