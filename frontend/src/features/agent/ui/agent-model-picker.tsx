"use client";

import {
  useCallback,
  useMemo,
  useRef,
  useState,
  type KeyboardEvent as ReactKeyboardEvent,
  type MouseEvent,
  type PointerEvent,
} from "react";
import { createPortal } from "react-dom";
import Link from "next/link";
import { Check, ChevronDown, ChevronRight, Pin } from "@/ui/icon-registry";
import type { AgentThinkingLevel } from "@/features/agent/contracts";
import type { AgentModel } from "@/features/agent/workspace/types";
import { POPOVER_SURFACE_CLASS } from "@/ui/popover";
import { cx } from "@/ui/utils";
import { useMountSubscription } from "@/hooks/use-mount-subscription";
import { splitVisibleAgentModels } from "./model-visibility";

type AgentModelPickerProps = {
  models: AgentModel[];
  selectedModel: string;
  defaultModel?: string;
  onSelect: (id: string) => void;
  onSetDefault?: (id: string) => void;
  loading: boolean;
  reasoningLevel?: AgentThinkingLevel;
  reasoningLevels?: readonly AgentThinkingLevel[];
  reasoningDisabled?: boolean;
  onSelectReasoning?: (level: AgentThinkingLevel) => void;
  open?: boolean;
  onOpenChange?: (open: boolean) => void;
};

const PANEL_GAP_PX = 6;
const VIEWPORT_MARGIN_PX = 8;

type ModelGroup = { key: string; name: string; models: AgentModel[] };
type PickerView = "inspector" | "models" | "reasoning";

const REASONING_LABELS: Record<AgentThinkingLevel, string> = {
  off: "Off",
  auto: "Auto",
  minimal: "Minimal",
  low: "Low",
  medium: "Medium",
  high: "High",
  xhigh: "XHigh",
  max: "Max",
};

const REASONING_MENU_LEVELS: readonly AgentThinkingLevel[] = [
  "auto",
  "minimal",
  "low",
  "medium",
  "high",
  "xhigh",
  "max",
  "off",
];

export function AgentModelPicker({
  models,
  selectedModel,
  defaultModel,
  onSelect,
  onSetDefault,
  loading,
  reasoningLevel,
  reasoningLevels = [],
  reasoningDisabled = false,
  onSelectReasoning,
  open: controlledOpen,
  onOpenChange,
}: AgentModelPickerProps) {
  const [internalOpen, setInternalOpen] = useState(false);
  const open = controlledOpen ?? internalOpen;
  const [present, setPresent] = useState(open);
  const [view, setView] = useState<PickerView>("inspector");
  const [showOtherModels, setShowOtherModels] = useState(false);
  const [modelQuery, setModelQuery] = useState("");
  const [openSource, setOpenSource] = useState<"pointer" | "keyboard">("keyboard");
  const active = models.find((model) => model.id === selectedModel) ?? null;
  const visible = useMemo(
    () => splitVisibleAgentModels(models, showOtherModels),
    [models, showOtherModels],
  );
  const groups = useMemo(
    () => groupModelsByController(visible.visibleModels),
    [visible.visibleModels],
  );
  const filteredGroups = useMemo(() => {
    const query = modelQuery.trim().toLocaleLowerCase();
    if (!query) return groups;
    return groups
      .map((group) => ({
        ...group,
        models: group.models.filter((model) =>
          [model.name, model.rawId, model.id, model.controllerName]
            .filter(Boolean)
            .some((value) => value?.toLocaleLowerCase().includes(query)),
        ),
      }))
      .filter((group) => group.models.length > 0);
  }, [groups, modelQuery]);
  const disabled = loading;
  const modelLabel = modelTriggerLabel(
    active,
    selectedModel,
    loading,
    visible.controllerModels.length,
  );
  const supportsReasoning = Boolean(
    reasoningLevel && onSelectReasoning && reasoningLevels.length > 1,
  );
  const effectiveReasoning = reasoningLevels.includes(reasoningLevel ?? "off")
    ? (reasoningLevel ?? "off")
    : (reasoningLevels.at(-1) ?? "off");
  const reasoningLabel = REASONING_LABELS[effectiveReasoning];
  const selectedModelNotRunning = !loading && Boolean(active && active.active === false);
  const anchorRef = useRef<HTMLDivElement | null>(null);
  const panelRef = useRef<HTMLDivElement | null>(null);
  const nestedPanelRef = useRef<HTMLDivElement | null>(null);
  const nestedAnchorRef = useRef<HTMLButtonElement | null>(null);
  const [nestedPosition, setNestedPosition] = useState({ top: 0, left: 0 });
  const [nestedReady, setNestedReady] = useState(false);
  const updateOpen = useCallback(
    (next: boolean) => {
      if (next) setPresent(true);
      if (controlledOpen === undefined) setInternalOpen(next);
      onOpenChange?.(next);
    },
    [controlledOpen, onOpenChange],
  );
  const close = useCallback(() => {
    updateOpen(false);
    setView("inspector");
    setNestedReady(false);
    setModelQuery("");
  }, [updateOpen]);
  const closeAndFocus = useCallback(
    (targetView: PickerView = "inspector") => {
      close();
      requestAnimationFrame(() =>
        anchorRef.current
          ?.querySelector<HTMLButtonElement>(`[data-picker-view="${targetView}"]`)
          ?.focus(),
      );
    },
    [close],
  );

  useMountSubscription(() => {
    if (open) {
      setPresent(true);
      return;
    }
    const timeout = window.setTimeout(() => setPresent(false), 90);
    return () => window.clearTimeout(timeout);
  }, [open]);

  useMountSubscription(() => {
    if (!open || openSource !== "keyboard") return;
    const frame = requestAnimationFrame(() => {
      const selector =
        view === "models"
          ? 'input[type="search"], [role^="menuitem"]:not(:disabled)'
          : '[role^="menuitem"]:not(:disabled)';
      panelRef.current?.querySelector<HTMLElement>(selector)?.focus();
    });
    return () => cancelAnimationFrame(frame);
  }, [open, openSource, view]);

  useMountSubscription(() => {
    if (!open || view === "inspector" || openSource !== "keyboard") return;
    const frame = requestAnimationFrame(() => {
      nestedPanelRef.current
        ?.querySelector<HTMLElement>('input[type="search"], [role^="menuitem"]:not(:disabled)')
        ?.focus();
    });
    return () => cancelAnimationFrame(frame);
  }, [open, openSource, view]);

  useMountSubscription(() => {
    if (!open) return;
    const onPointerDown = (event: globalThis.PointerEvent) => {
      if (!(event.target instanceof Node)) return;
      if (
        anchorRef.current?.contains(event.target) ||
        panelRef.current?.contains(event.target) ||
        nestedPanelRef.current?.contains(event.target)
      )
        return;
      close();
    };
    const onKeyDown = (event: globalThis.KeyboardEvent) => {
      if (event.key !== "Escape") return;
      event.preventDefault();
      closeAndFocus();
    };
    document.addEventListener("pointerdown", onPointerDown, true);
    document.addEventListener("keydown", onKeyDown);
    return () => {
      document.removeEventListener("pointerdown", onPointerDown, true);
      document.removeEventListener("keydown", onKeyDown);
    };
  }, [close, closeAndFocus, open]);

  const placeNestedPanel = useCallback(() => {
    const trigger = nestedAnchorRef.current;
    const panel = nestedPanelRef.current;
    if (!trigger || !panel) return;
    const rect = trigger.getBoundingClientRect();
    const width = panel.offsetWidth;
    const gap = PANEL_GAP_PX;
    const left =
      rect.right + gap + width <= window.innerWidth - VIEWPORT_MARGIN_PX
        ? rect.right + gap
        : rect.left - width - gap;
    const top = Math.min(
      Math.max(VIEWPORT_MARGIN_PX, rect.top),
      Math.max(VIEWPORT_MARGIN_PX, window.innerHeight - panel.offsetHeight - VIEWPORT_MARGIN_PX),
    );
    setNestedPosition({
      top: Math.round(top),
      left: Math.round(Math.max(VIEWPORT_MARGIN_PX, left)),
    });
    setNestedReady(true);
  }, []);

  const openNested = useCallback(
    (nextView: Exclude<PickerView, "inspector">, trigger: HTMLButtonElement | null) => {
      nestedAnchorRef.current = trigger;
      setNestedReady(false);
      setView(nextView);
      requestAnimationFrame(placeNestedPanel);
    },
    [placeNestedPanel],
  );

  const closeNestedAndFocus = useCallback(() => {
    const trigger = nestedAnchorRef.current;
    setNestedReady(false);
    setView("inspector");
    requestAnimationFrame(() => trigger?.focus());
  }, []);

  useMountSubscription(() => {
    if (!open || view === "inspector") return;
    const frame = requestAnimationFrame(placeNestedPanel);
    window.addEventListener("resize", placeNestedPanel);
    window.addEventListener("scroll", placeNestedPanel, true);
    return () => {
      cancelAnimationFrame(frame);
      window.removeEventListener("resize", placeNestedPanel);
      window.removeEventListener("scroll", placeNestedPanel, true);
    };
  }, [open, placeNestedPanel, view]);

  const placePanel = useCallback((node: HTMLDivElement | null) => {
    panelRef.current = node;
    if (!node) return;
    const place = () => {
      const anchor = anchorRef.current?.getBoundingClientRect();
      if (!anchor) return;
      const { offsetWidth: width, offsetHeight: height } = node;
      const maxLeft = window.innerWidth - width - VIEWPORT_MARGIN_PX;
      const left = Math.min(Math.max(VIEWPORT_MARGIN_PX, anchor.right - width), maxLeft);
      const fitsBelow =
        anchor.bottom + height + PANEL_GAP_PX <= window.innerHeight - VIEWPORT_MARGIN_PX;
      const desiredTop = fitsBelow
        ? anchor.bottom + PANEL_GAP_PX
        : anchor.top - height - PANEL_GAP_PX;
      const maxTop = Math.max(VIEWPORT_MARGIN_PX, window.innerHeight - height - VIEWPORT_MARGIN_PX);
      const top = Math.min(maxTop, Math.max(VIEWPORT_MARGIN_PX, desiredTop));
      node.dataset.placement = fitsBelow ? "below" : "above";
      node.style.left = `${Math.round(Math.max(VIEWPORT_MARGIN_PX, left))}px`;
      node.style.top = `${Math.round(top)}px`;
    };
    place();
    const observer = new ResizeObserver(place);
    observer.observe(node);
    window.addEventListener("resize", place);
    window.addEventListener("scroll", place, true);
    return () => {
      observer.disconnect();
      window.removeEventListener("resize", place);
      window.removeEventListener("scroll", place, true);
      panelRef.current = null;
    };
  }, []);
  return (
    <div
      ref={anchorRef}
      className="relative min-w-0 shrink"
      onBlur={(event) => {
        const nextTarget = event.relatedTarget;
        if (nextTarget instanceof Node) {
          if (event.currentTarget.contains(nextTarget)) return;
          if (panelRef.current?.contains(nextTarget)) return;
          if (nestedPanelRef.current?.contains(nextTarget)) return;
        }
        close();
      }}
      onPointerDown={(event) => {
        setOpenSource("pointer");
        stopToolbarEvent(event);
      }}
      onMouseDown={(event) => {
        setOpenSource("pointer");
        stopToolbarEvent(event);
      }}
      onKeyDown={() => setOpenSource("keyboard")}
    >
      <div className="flex min-w-0 items-center gap-1">
        <ModelPickerTrigger
          view="inspector"
          kind={supportsReasoning ? "Reasoning" : "Model"}
          label={supportsReasoning ? reasoningLabel : modelLabel}
          title={supportsReasoning ? `Reasoning: ${reasoningLabel}` : active?.name || modelLabel}
          disabled={disabled}
          open={open}
          notRunning={selectedModelNotRunning}
          onToggle={(event) => {
            setOpenSource(event.detail > 0 ? "pointer" : "keyboard");
            if (disabled) return;
            if (open && view === "inspector") close();
            else {
              setView("inspector");
              updateOpen(true);
            }
          }}
        />
      </div>
      {present && typeof document !== "undefined"
        ? createPortal(
            <div
              ref={placePanel}
              className={`composer-popover ${open ? "composer-popover-enter" : "composer-popover-exit pointer-events-none"} fixed z-[300] w-[11rem] max-w-[calc(100vw-1rem)] overflow-visible p-1 ${POPOVER_SURFACE_CLASS}`}
              role="menu"
              aria-hidden={!open}
              data-open-source={openSource}
              aria-label="Model settings"
              onKeyDown={(event) => {
                setOpenSource("keyboard");
                handleMenuKeyDown(event, closeAndFocus);
              }}
              onPointerDown={stopToolbarEvent}
              onMouseDown={stopToolbarEvent}
            >
              <PickerInspector
                activeView={view}
                modelLabel={modelLabel}
                reasoningLabel={supportsReasoning ? reasoningLabel : null}
                reasoningDisabled={reasoningDisabled}
                onOpenModel={(trigger) => openNested("models", trigger)}
                onOpenReasoning={(trigger) => openNested("reasoning", trigger)}
              />
            </div>,
            document.body,
          )
        : null}
      {present && open && view !== "inspector" && typeof document !== "undefined"
        ? createPortal(
            <div
              ref={(node) => {
                nestedPanelRef.current = node;
                if (node) requestAnimationFrame(placeNestedPanel);
              }}
              className={`fixed z-[301] max-w-[calc(100vw-1rem)] overflow-visible p-1 ${nestedReady ? "composer-popover-enter" : ""} ${view === "models" ? "w-[18rem]" : "w-[11rem]"} ${POPOVER_SURFACE_CLASS}`}
              style={{
                top: nestedPosition.top,
                left: nestedPosition.left,
                visibility: nestedReady ? "visible" : "hidden",
              }}
              role="menu"
              aria-label={view === "models" ? "Models" : "Reasoning"}
              onKeyDown={(event) => {
                setOpenSource("keyboard");
                if (event.key === "ArrowLeft") {
                  event.preventDefault();
                  event.stopPropagation();
                  closeNestedAndFocus();
                  return;
                }
                handleMenuKeyDown(event, closeAndFocus);
              }}
              onPointerDown={stopToolbarEvent}
              onMouseDown={stopToolbarEvent}
            >
              {view === "models" ? (
                <ModelList
                  groups={filteredGroups}
                  query={modelQuery}
                  onQueryChange={setModelQuery}
                  selectedModel={selectedModel}
                  defaultModel={defaultModel}
                  showOtherModels={showOtherModels}
                  otherModelCount={visible.otherModels.length}
                  onSelect={(modelId) => {
                    onSelect(modelId);
                    closeAndFocus();
                  }}
                  onSetDefault={onSetDefault}
                  onToggleOtherModels={() => setShowOtherModels((current) => !current)}
                  onClose={close}
                />
              ) : onSelectReasoning ? (
                <ReasoningList
                  value={effectiveReasoning}
                  levels={reasoningLevels}
                  disabled={reasoningDisabled}
                  onSelect={(level) => {
                    onSelectReasoning(level);
                    closeAndFocus();
                  }}
                />
              ) : null}
            </div>,
            document.body,
          )
        : null}
    </div>
  );
}

function PickerHeader({ title }: { title: string }) {
  return (
    <div className="flex h-7 items-center gap-0.5 border-b border-(--border) px-1 pb-0.5">
      <span className="px-1 text-[length:var(--fs-sm)] font-medium text-(--dim)">{title}</span>
    </div>
  );
}

function PickerInspector({
  activeView,
  modelLabel,
  reasoningLabel,
  reasoningDisabled,
  onOpenModel,
  onOpenReasoning,
}: {
  activeView: PickerView;
  modelLabel: string;
  reasoningLabel: string | null;
  reasoningDisabled: boolean;
  onOpenModel: (anchor: HTMLButtonElement | null) => void;
  onOpenReasoning: (anchor: HTMLButtonElement | null) => void;
}) {
  return (
    <div className="grid gap-0.5 p-1">
      {reasoningLabel ? (
        <button
          type="button"
          role="menuitem"
          aria-haspopup="menu"
          aria-expanded={activeView === "reasoning"}
          disabled={reasoningDisabled}
          onClick={(event) => onOpenReasoning(event.currentTarget)}
          onPointerEnter={(event) => onOpenReasoning(event.currentTarget)}
          onKeyDown={(event) => {
            if (event.key !== "ArrowRight") return;
            event.preventDefault();
            event.stopPropagation();
            onOpenReasoning(event.currentTarget);
          }}
          className={cx(
            "flex h-7 w-full items-center gap-2 rounded-[4px] px-2 text-left text-[length:var(--fs-sm)] text-(--fg) transition-[background-color,color] duration-[var(--motion-fast)] hover:bg-(--hover) active:bg-(--active) focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-(--focus-ring) disabled:opacity-45",
            activeView === "reasoning" && "bg-(--hover)",
          )}
        >
          <span className="min-w-0 flex-1">Effort</span>
          <span className="max-w-[5rem] truncate text-[length:var(--fs-xs)] text-(--dim)">
            {reasoningLabel}
          </span>
          <ChevronRight className="h-3 w-3 shrink-0 text-(--dim)" />
        </button>
      ) : null}
      <button
        type="button"
        role="menuitem"
        aria-haspopup="menu"
        aria-expanded={activeView === "models"}
        onClick={(event) => onOpenModel(event.currentTarget)}
        onPointerEnter={(event) => onOpenModel(event.currentTarget)}
        onKeyDown={(event) => {
          if (event.key !== "ArrowRight") return;
          event.preventDefault();
          event.stopPropagation();
          onOpenModel(event.currentTarget);
        }}
        className={cx(
          "flex h-7 w-full items-center gap-2 rounded-[4px] px-2 text-left text-[length:var(--fs-sm)] text-(--fg) transition-[background-color,color] duration-[var(--motion-fast)] hover:bg-(--hover) active:bg-(--active) focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-(--focus-ring)",
          activeView === "models" && "bg-(--hover)",
        )}
      >
        <span className="min-w-0 flex-1">Model</span>
        <span className="max-w-[5rem] truncate text-[length:var(--fs-xs)] text-(--dim)">
          {modelLabel}
        </span>
        <ChevronRight className="h-3 w-3 shrink-0 text-(--dim)" />
      </button>
    </div>
  );
}

function ModelList({
  groups,
  query,
  onQueryChange,
  selectedModel,
  defaultModel,
  showOtherModels,
  otherModelCount,
  onSelect,
  onSetDefault,
  onToggleOtherModels,
  onClose,
}: {
  groups: ModelGroup[];
  query: string;
  onQueryChange: (query: string) => void;
  selectedModel: string;
  defaultModel?: string;
  showOtherModels: boolean;
  otherModelCount: number;
  onSelect: (modelId: string) => void;
  onSetDefault?: (modelId: string) => void;
  onToggleOtherModels: () => void;
  onClose: () => void;
}) {
  return (
    <div>
      <PickerHeader title="Model" />
      <div className="px-1.5 pt-1">
        <input
          type="search"
          value={query}
          onChange={(event) => onQueryChange(event.target.value)}
          placeholder="Search models"
          aria-label="Search models"
          className="h-7 w-full rounded-[4px] border border-(--border) bg-(--color-input) px-2 text-[length:var(--fs-xs)] text-(--fg) outline-none transition-[border-color,background-color] duration-[var(--motion-fast)] placeholder:text-(--dim) focus:border-(--accent) focus:bg-(--input-focus)"
        />
      </div>
      {otherModelCount > 0 ? (
        <button
          type="button"
          role="menuitemcheckbox"
          aria-checked={showOtherModels}
          onClick={onToggleOtherModels}
          className="mt-1 flex min-h-8 w-full items-center gap-2 rounded-[4px] px-2 text-left text-[length:var(--fs-sm)] text-(--fg) transition-colors duration-[var(--motion-fast)] hover:bg-(--hover)"
        >
          <span className="min-w-0 flex-1">
            <span className="block font-medium">Other models</span>
            <span className="block truncate text-[length:var(--fs-xs)] text-(--dim)">
              Pi and connected providers · {otherModelCount}
            </span>
          </span>
          <span
            aria-hidden="true"
            className={cx(
              "relative h-4 w-7 shrink-0 rounded-full border border-(--border) bg-(--color-input) transition-colors duration-[var(--motion-fast)]",
              showOtherModels && "border-(--accent) bg-(--accent)",
            )}
          >
            <span
              className={cx(
                "absolute left-0.5 top-0.5 h-2.5 w-2.5 rounded-full bg-(--fg) transition-transform duration-[var(--motion-fast)]",
                showOtherModels && "translate-x-3",
              )}
            />
          </span>
        </button>
      ) : null}
      <div className="max-h-[min(24rem,55vh)] overflow-y-auto pt-1">
        {groups.length === 0 ? (
          <div className="w-full min-w-0 px-2.5 py-2 text-[length:var(--fs-sm)] text-(--dim)">
            <p>
              {query
                ? `No models match “${query}”.`
                : otherModelCount > 0
                  ? "No controller models are available."
                  : "No chat models are available."}
            </p>
            <Link
              href="/models"
              role="menuitem"
              onClick={onClose}
              className="mt-2 inline-flex h-7 items-center rounded-lg bg-(--active) px-2.5 text-(--fg) transition-colors duration-[var(--motion-fast)] hover:bg-(--hover)"
            >
              Open Models
            </Link>
          </div>
        ) : (
          groups.map((group) => (
            <div key={group.key} className="not-first:mt-1.5">
              {groups.length > 1 ? (
                <div className="flex h-6 items-center justify-between px-2 text-[length:var(--fs-xs)] font-medium text-(--dim)">
                  <span className="truncate">{group.name}</span>
                  <span className="font-mono text-[length:var(--fs-2xs)]">
                    {group.models.length}
                  </span>
                </div>
              ) : null}
              <ModelOptions
                models={group.models}
                selectedModel={selectedModel}
                defaultModel={defaultModel}
                onSelect={onSelect}
                onSetDefault={onSetDefault}
              />
            </div>
          ))
        )}
      </div>
    </div>
  );
}

function ReasoningList({
  value,
  levels,
  disabled,
  onSelect,
}: {
  value: AgentThinkingLevel;
  levels: readonly AgentThinkingLevel[];
  disabled: boolean;
  onSelect: (level: AgentThinkingLevel) => void;
}) {
  return (
    <div>
      <PickerHeader title="Effort" />
      <div className="grid gap-0.5 pt-1">
        {REASONING_MENU_LEVELS.filter((level) => levels.includes(level)).map((level) => (
          <button
            key={level}
            type="button"
            role="menuitemradio"
            aria-checked={level === value}
            disabled={disabled}
            onClick={() => onSelect(level)}
            className={cx(
              "flex h-7 w-full items-center gap-2 rounded-[4px] px-2 text-left text-[length:var(--fs-sm)] text-(--fg) transition-colors duration-[var(--motion-fast)] hover:bg-(--hover) focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-(--focus-ring) disabled:opacity-45",
              level === value && "bg-(--color-input)",
            )}
          >
            <span className="flex-1">{REASONING_LABELS[level]}</span>
            {level === value ? <Check className="h-3 w-3" /> : null}
          </button>
        ))}
      </div>
    </div>
  );
}

function ModelPickerTrigger({
  view,
  kind,
  label,
  title,
  disabled,
  open,
  notRunning,
  onToggle,
}: {
  view: PickerView;
  kind: "Model" | "Reasoning";
  label: string;
  title: string;
  disabled: boolean;
  open: boolean;
  notRunning: boolean;
  onToggle: (event: MouseEvent<HTMLButtonElement>) => void;
}) {
  return (
    <button
      type="button"
      data-picker-view={view}
      onPointerDown={stopToolbarEvent}
      onMouseDown={stopToolbarEvent}
      onClick={onToggle}
      disabled={disabled}
      className={cx(
        "group/model inline-flex !h-6 !min-h-6 !min-w-0 max-w-[10rem] items-center gap-1 rounded-[6px] bg-transparent px-1.5 text-[length:var(--fs-sm)] whitespace-nowrap text-(--fg)/78 transition-[background-color,color,transform] duration-[var(--motion-fast)] hover:bg-(--hover) hover:text-(--fg) active:scale-[0.98] active:bg-(--active) focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-(--focus-ring) disabled:opacity-60",
        open && "bg-(--active) text-(--fg)",
      )}
      title={notRunning ? `${title} is not running — launch it or pick a running model` : title}
      aria-label={`${kind}: ${title}${notRunning ? " (not running)" : ""}`}
      aria-expanded={open}
      aria-haspopup="menu"
    >
      <span className="mr-0.5 text-[length:var(--fs-xs)] text-(--dim)">{kind}</span>
      <span className="min-w-0 truncate text-left text-(--fg)/90">{label}</span>
      {notRunning ? <span className="h-1.5 w-1.5 shrink-0 rounded-full bg-(--warn)" /> : null}
      <ChevronDown className="pointer-events-none h-3 w-3 shrink-0 text-(--dim)" />
    </button>
  );
}

function ModelOptions({
  models,
  selectedModel,
  defaultModel,
  onSelect,
  onSetDefault,
}: {
  models: AgentModel[];
  selectedModel: string;
  defaultModel?: string;
  onSelect: (modelId: string) => void;
  onSetDefault?: (modelId: string) => void;
}) {
  return models.map((model) => (
    <ModelOption
      key={model.id}
      model={model}
      selected={model.id === selectedModel}
      isDefault={model.id === defaultModel}
      onSelect={onSelect}
      onSetDefault={onSetDefault}
    />
  ));
}

function ModelOption({
  model,
  selected,
  isDefault,
  onSelect,
  onSetDefault,
}: {
  model: AgentModel;
  selected: boolean;
  isDefault: boolean;
  onSelect: (modelId: string) => void;
  onSetDefault?: (modelId: string) => void;
}) {
  const label = model.rawId || model.name;
  return (
    <div
      className={cx(
        "group/model-option flex min-h-7 w-full min-w-0 items-center rounded-[4px] text-[length:var(--fs-sm)] text-(--fg) transition-colors duration-[var(--motion-fast)] hover:bg-(--hover)",
        selected && "bg-(--color-input)",
      )}
    >
      <button
        type="button"
        role="menuitemradio"
        aria-checked={selected}
        onClick={() => onSelect(model.id)}
        className="flex min-h-7 min-w-0 flex-1 items-center gap-2 rounded-[4px] pl-2 text-left focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-(--focus-ring)"
      >
        <span className="min-w-0 flex-1 truncate" title={label}>
          {label}
        </span>
        {selected ? <Check className="h-3 w-3 shrink-0 text-(--fg)" /> : null}
      </button>
      {onSetDefault ? (
        <button
          type="button"
          onClick={() => onSetDefault(model.id)}
          aria-label={isDefault ? `${label} is the default model` : `Set ${label} as default model`}
          title={isDefault ? "Default model" : "Set as default"}
          className={cx(
            "mr-0.5 inline-flex h-6 w-6 shrink-0 items-center justify-center rounded-[4px] text-(--dim) opacity-0 transition-[background-color,color,opacity] duration-[var(--motion-fast)] hover:bg-(--active) hover:text-(--fg) focus-visible:opacity-100 focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-(--focus-ring) group-hover/model-option:opacity-100 group-focus-within/model-option:opacity-100",
            isDefault && "bg-(--active) text-(--fg) opacity-100",
          )}
        >
          <Pin className={cx("h-3 w-3", isDefault && "fill-current")} strokeWidth={1.5} />
        </button>
      ) : null}
    </div>
  );
}

function handleMenuKeyDown(event: ReactKeyboardEvent<HTMLDivElement>, close: () => void) {
  if (event.key === "Escape") {
    event.preventDefault();
    close();
    return;
  }
  const items = [...event.currentTarget.querySelectorAll<HTMLElement>('[role^="menuitem"]')].filter(
    (item) => !item.hasAttribute("disabled"),
  );
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

function modelTriggerLabel(
  active: AgentModel | null,
  selectedModel: string,
  loading: boolean,
  modelCount: number,
): string {
  const fallbackLabel = selectedModel || (modelCount === 0 ? "No models" : "model");
  if (loading) return active?.rawId || active?.name || fallbackLabel || "Loading…";
  return active?.rawId || active?.name || fallbackLabel;
}

function controllerGroupKey(model: AgentModel): string {
  return model.controllerUrl ?? model.controllerName ?? "primary";
}

function groupModelsByController(models: AgentModel[]): ModelGroup[] {
  const groups = new Map<string, ModelGroup>();
  for (const model of models) {
    const key = controllerGroupKey(model);
    const existing = groups.get(key);
    if (existing) existing.models.push(model);
    else groups.set(key, { key, name: model.controllerName ?? "local", models: [model] });
  }
  return [...groups.values()];
}

function stopToolbarEvent(event: MouseEvent | PointerEvent) {
  event.stopPropagation();
}
