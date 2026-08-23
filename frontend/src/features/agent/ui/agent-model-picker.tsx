"use client";

import {
  type KeyboardEvent as ReactKeyboardEvent,
  type MouseEvent,
  type PointerEvent,
} from "react";
import Link from "next/link";
import { Check, ChevronDown, ChevronRight, Pin } from "@/ui/icon-registry";
import type { AgentThinkingLevel } from "@/features/agent/contracts";
import type { AgentModel } from "@/features/agent/workspace/types";
import { cx } from "@/ui/utils";

export { AgentModelPicker } from "./agent-model-picker-controller";

export type AgentModelPickerProps = {
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

export type ModelGroup = { key: string; name: string; models: AgentModel[] };
export type PickerView = "inspector" | "models" | "reasoning";

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

export function PickerHeader({ title }: { title: string }) {
  return (
    <div className="flex h-7 items-center gap-0.5 border-b border-(--border) px-1 pb-0.5">
      <span className="px-1 text-[length:var(--fs-sm)] font-medium text-(--dim)">{title}</span>
    </div>
  );
}

export function PickerInspector({
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

export function ModelList({
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

export function ReasoningList({
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

export function ModelPickerTrigger({
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

export function ModelOptions({
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

export function ModelOption({
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

export function handleMenuKeyDown(event: ReactKeyboardEvent<HTMLDivElement>, close: () => void) {
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

export function modelTriggerLabel(
  active: AgentModel | null,
  selectedModel: string,
  loading: boolean,
  modelCount: number,
): string {
  const fallbackLabel = selectedModel || (modelCount === 0 ? "No models" : "model");
  if (loading) return active?.rawId || active?.name || fallbackLabel || "Loading…";
  return active?.rawId || active?.name || fallbackLabel;
}

export function controllerGroupKey(model: AgentModel): string {
  return model.controllerUrl ?? model.controllerName ?? "primary";
}

export function groupModelsByController(models: AgentModel[]): ModelGroup[] {
  const groups = new Map<string, ModelGroup>();
  for (const model of models) {
    const key = controllerGroupKey(model);
    const existing = groups.get(key);
    if (existing) existing.models.push(model);
    else groups.set(key, { key, name: model.controllerName ?? "local", models: [model] });
  }
  return [...groups.values()];
}

export function stopToolbarEvent(event: MouseEvent | PointerEvent) {
  event.stopPropagation();
}
