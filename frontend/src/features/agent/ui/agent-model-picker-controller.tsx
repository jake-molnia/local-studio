"use client";

import {
  useCallback,
  useMemo,
  useRef,
  useState,
  type KeyboardEvent as ReactKeyboardEvent,
} from "react";
import { createPortal } from "react-dom";
import type { AgentThinkingLevel } from "@/features/agent/contracts";
import type { AgentModel } from "@/features/agent/workspace/types";
import { ChevronRight } from "@/ui/icon-registry";
import { POPOVER_SURFACE_CLASS } from "@/ui/popover";
import { cx } from "@/ui/utils";
import { useMountSubscription } from "@/hooks/use-mount-subscription";
import {
  activeModelChoice,
  availableModelCompanies,
  buildModelChoices,
  routeForChoice,
  selectedModelRoute,
  type ModelChoice,
} from "./agent-model-picker-data";
import {
  ComposerPickerTrigger,
  filteredChoices,
  ModelPickerPanel,
  SimplePickerOption,
  SimplePickerPanel,
  stopToolbarEvent,
} from "./agent-model-picker-components";

type AgentModelPickerProps = {
  models: AgentModel[];
  selectedModel: string;
  selectedRoute?: string;
  defaultModel?: string;
  onSelect: (modelId: string, routeId: string) => void;
  onSetDefault?: (modelId: string, routeId: string) => void;
  loading: boolean;
  reasoningLevel?: AgentThinkingLevel;
  reasoningLevels?: readonly AgentThinkingLevel[];
  reasoningDisabled?: boolean;
  onSelectReasoning?: (level: AgentThinkingLevel) => void;
  open?: boolean;
  onOpenChange?: (open: boolean) => void;
};

type PickerView = "inspector" | "models" | "reasoning" | "provider";

const PANEL_GAP_PX = 6;
const VIEWPORT_MARGIN_PX = 8;
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
  selectedRoute,
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
  const [view, setView] = useState<PickerView>("inspector");
  const [present, setPresent] = useState(controlledOpen ?? false);
  const [query, setQuery] = useState("");
  const [selectedCompany, setSelectedCompany] = useState("openai");
  const [openSource, setOpenSource] = useState<"pointer" | "keyboard">("keyboard");
  const open = controlledOpen ?? internalOpen;
  const choices = useMemo(() => buildModelChoices(models), [models]);
  const activeChoice = useMemo(
    () => activeModelChoice(choices, selectedModel),
    [choices, selectedModel],
  );
  const activeRoute = useMemo(
    () => selectedModelRoute(models, selectedModel, selectedRoute),
    [models, selectedModel, selectedRoute],
  );
  const companies = useMemo(() => availableModelCompanies(choices), [choices]);
  const effectiveReasoning = reasoningLevels.includes(reasoningLevel ?? "off")
    ? (reasoningLevel ?? "off")
    : (reasoningLevels.at(-1) ?? "off");
  const supportsReasoning = Boolean(
    onSelectReasoning && reasoningLevel && reasoningLevels.length > 1,
  );
  const providerRoutes = activeChoice?.routes ?? [];
  const supportsProviderSelection = providerRoutes.length > 1;
  const activeModel = models.find((model) => model.id === selectedModel) ?? null;
  const selectedModelNotRunning = !loading && Boolean(activeModel && !activeModel.active);
  const anchorRef = useRef<HTMLDivElement | null>(null);
  const activeTriggerRef = useRef<HTMLButtonElement | null>(null);
  const panelRef = useRef<HTMLDivElement | null>(null);
  const nestedTriggerRef = useRef<HTMLButtonElement | null>(null);
  const nestedPanelRef = useRef<HTMLDivElement | null>(null);
  const searchRef = useRef<HTMLInputElement | null>(null);

  const updateOpen = useCallback(
    (next: boolean) => {
      if (next) setPresent(true);
      if (controlledOpen === undefined) setInternalOpen(next);
      onOpenChange?.(next);
    },
    [controlledOpen, onOpenChange],
  );

  const close = useCallback(
    (restoreFocus = false) => {
      updateOpen(false);
      setView("inspector");
      setQuery("");
      if (restoreFocus) requestAnimationFrame(() => activeTriggerRef.current?.focus());
    },
    [updateOpen],
  );

  const togglePicker = useCallback(
    (trigger: HTMLButtonElement, pointer: boolean) => {
      setOpenSource(pointer ? "pointer" : "keyboard");
      activeTriggerRef.current = trigger;
      if (open) {
        close();
        return;
      }
      setView("inspector");
      updateOpen(true);
    },
    [close, open, updateOpen],
  );

  const openNested = useCallback(
    (nextView: Exclude<PickerView, "inspector">, trigger: HTMLButtonElement) => {
      nestedTriggerRef.current = trigger;
      if (nextView === "models") {
        setSelectedCompany(activeChoice?.company.key ?? companies[0]?.key ?? "local");
        setQuery("");
      }
      setView(nextView);
    },
    [activeChoice?.company.key, companies],
  );

  const closeNested = useCallback(() => {
    const trigger = nestedTriggerRef.current;
    setView("inspector");
    requestAnimationFrame(() => trigger?.focus());
  }, []);

  useMountSubscription(() => {
    if (open) {
      setPresent(true);
      return;
    }
    const timeout = window.setTimeout(() => setPresent(false), 90);
    return () => window.clearTimeout(timeout);
  }, [open]);

  useMountSubscription(() => {
    if (!open) return;
    const onPointerDown = (event: globalThis.PointerEvent) => {
      if (!(event.target instanceof Node)) return;
      if (
        anchorRef.current?.contains(event.target) ||
        panelRef.current?.contains(event.target) ||
        nestedPanelRef.current?.contains(event.target)
      ) {
        return;
      }
      close();
    };
    const onKeyDown = (event: globalThis.KeyboardEvent) => {
      if (event.defaultPrevented) return;
      if (event.key !== "Escape") return;
      event.preventDefault();
      if (view === "inspector") close(true);
      else closeNested();
    };
    document.addEventListener("pointerdown", onPointerDown, true);
    document.addEventListener("keydown", onKeyDown);
    return () => {
      document.removeEventListener("pointerdown", onPointerDown, true);
      document.removeEventListener("keydown", onKeyDown);
    };
  }, [close, closeNested, open, view]);

  useMountSubscription(() => {
    if (!open) return;
    const { documentElement, body } = document;
    const documentOverscroll = documentElement.style.overscrollBehavior;
    const bodyOverflow = body.style.overflow;
    documentElement.style.overscrollBehavior = "contain";
    body.style.overflow = "hidden";
    return () => {
      documentElement.style.overscrollBehavior = documentOverscroll;
      body.style.overflow = bodyOverflow;
    };
  }, [open]);

  useMountSubscription(() => {
    if (!open) return;
    const frame = requestAnimationFrame(() => {
      if (view === "models") {
        searchRef.current?.focus({ preventScroll: true });
      } else if (view === "inspector" && openSource === "keyboard") {
        panelRef.current?.querySelector<HTMLElement>('[role^="menuitem"]:not(:disabled)')?.focus();
      } else if (openSource === "keyboard") {
        nestedPanelRef.current
          ?.querySelector<HTMLElement>('[role^="menuitem"]:not(:disabled)')
          ?.focus();
      }
    });
    return () => cancelAnimationFrame(frame);
  }, [open, openSource, view]);

  const placePanel = useCallback((node: HTMLDivElement | null) => {
    panelRef.current = node;
    if (!node) return;
    const place = () => {
      const anchor = activeTriggerRef.current?.getBoundingClientRect();
      if (!anchor) return;
      const width = node.offsetWidth;
      const height = node.offsetHeight;
      const maxLeft = window.innerWidth - width - VIEWPORT_MARGIN_PX;
      const left = Math.min(Math.max(VIEWPORT_MARGIN_PX, anchor.left), maxLeft);
      const fitsBelow =
        anchor.bottom + height + PANEL_GAP_PX <= window.innerHeight - VIEWPORT_MARGIN_PX;
      const desiredTop = fitsBelow
        ? anchor.bottom + PANEL_GAP_PX
        : anchor.top - height - PANEL_GAP_PX;
      const maxTop = Math.max(VIEWPORT_MARGIN_PX, window.innerHeight - height - VIEWPORT_MARGIN_PX);
      node.style.left = `${Math.round(Math.max(VIEWPORT_MARGIN_PX, left))}px`;
      node.style.top = `${Math.round(Math.min(maxTop, Math.max(VIEWPORT_MARGIN_PX, desiredTop)))}px`;
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

  const placeNestedPanel = useCallback((node: HTMLDivElement | null) => {
    nestedPanelRef.current = node;
    if (!node) return;
    const place = () => {
      const anchor = nestedTriggerRef.current?.getBoundingClientRect();
      if (!anchor) return;
      const width = node.offsetWidth;
      const height = node.offsetHeight;
      const fitsRight =
        anchor.right + PANEL_GAP_PX + width <= window.innerWidth - VIEWPORT_MARGIN_PX;
      const desiredLeft = fitsRight
        ? anchor.right + PANEL_GAP_PX
        : anchor.left - width - PANEL_GAP_PX;
      const maxLeft = Math.max(VIEWPORT_MARGIN_PX, window.innerWidth - width - VIEWPORT_MARGIN_PX);
      const maxTop = Math.max(VIEWPORT_MARGIN_PX, window.innerHeight - height - VIEWPORT_MARGIN_PX);
      node.style.left = `${Math.round(Math.min(maxLeft, Math.max(VIEWPORT_MARGIN_PX, desiredLeft)))}px`;
      node.style.top = `${Math.round(Math.min(maxTop, Math.max(VIEWPORT_MARGIN_PX, anchor.top)))}px`;
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
      nestedPanelRef.current = null;
    };
  }, []);

  const selectChoice = useCallback(
    (choice: ModelChoice) => {
      const route = routeForChoice(choice, activeRoute);
      if (!route) return;
      onSelect(choice.model.id, route.route.id);
      close(true);
    },
    [activeRoute, close, onSelect],
  );

  return (
    <div
      ref={anchorRef}
      className="flex min-w-0 shrink items-center gap-0.5"
      onPointerDown={(event) => {
        setOpenSource("pointer");
        stopToolbarEvent(event);
      }}
      onMouseDown={stopToolbarEvent}
      onKeyDown={() => setOpenSource("keyboard")}
    >
      <ComposerPickerTrigger
        label={modelTriggerLabel(activeChoice, selectedModel, loading, choices.length)}
        title={`Model settings: ${activeChoice?.label || selectedModel || "No models"}`}
        company={activeChoice?.company}
        disabled={loading}
        open={open}
        notRunning={selectedModelNotRunning}
        onToggle={(event) => togglePicker(event.currentTarget, event.detail > 0)}
      />
      {present && typeof document !== "undefined"
        ? createPortal(
            <div
              ref={placePanel}
              className={cx(
                `composer-popover fixed z-[300] w-[12rem] max-w-[calc(100vw-1rem)] overflow-visible p-1 ${POPOVER_SURFACE_CLASS}`,
                open ? "composer-popover-enter" : "composer-popover-exit pointer-events-none",
              )}
              role="menu"
              aria-label="Model settings"
              aria-hidden={!open}
              data-open-source={openSource}
              data-model-picker-content
              onKeyDown={(event) => {
                setOpenSource("keyboard");
                handleMenuKeyDown(event, () => close(true));
              }}
              onPointerDown={stopToolbarEvent}
              onMouseDown={stopToolbarEvent}
            >
              <PickerInspector
                activeView={view}
                modelLabel={modelTriggerLabel(activeChoice, selectedModel, loading, choices.length)}
                effortLabel={supportsReasoning ? REASONING_LABELS[effectiveReasoning] : null}
                providerLabel={supportsProviderSelection && activeRoute ? activeRoute.label : null}
                onOpen={openNested}
              />
            </div>,
            document.body,
          )
        : null}
      {present && open && view !== "inspector" && typeof document !== "undefined"
        ? createPortal(
            <div
              ref={placeNestedPanel}
              className={cx(
                `composer-popover fixed z-[301] max-w-[calc(100vw-1rem)] ${POPOVER_SURFACE_CLASS}`,
                view === "models"
                  ? "h-[min(21.625rem,calc(100vh-1rem))] w-[22.5rem] overflow-hidden p-0"
                  : "w-[11rem] overflow-hidden p-1",
              )}
              role="menu"
              aria-label={view === "models" ? "Models" : "Model options"}
              data-model-picker-content
              onKeyDown={(event) => {
                setOpenSource("keyboard");
                if (event.key === "ArrowLeft") {
                  event.preventDefault();
                  event.stopPropagation();
                  closeNested();
                  return;
                }
                if (view === "models") {
                  handleModelPickerKeyDown(event, () => {
                    const first = filteredChoices(choices, selectedCompany, query)[0];
                    if (first) selectChoice(first);
                  });
                  return;
                }
                handleMenuKeyDown(event, closeNested);
              }}
              onPointerDown={stopToolbarEvent}
              onMouseDown={stopToolbarEvent}
            >
              {view === "models" ? (
                <ModelPickerPanel
                  choices={choices}
                  companies={companies}
                  selectedCompany={selectedCompany}
                  onSelectCompany={setSelectedCompany}
                  query={query}
                  onQueryChange={setQuery}
                  searchRef={searchRef}
                  selectedModel={selectedModel}
                  defaultModel={defaultModel}
                  onSelect={selectChoice}
                  onSetDefault={onSetDefault}
                  activeRoute={activeRoute}
                  onClose={() => close()}
                />
              ) : view === "reasoning" && onSelectReasoning ? (
                <SimplePickerPanel title="Effort">
                  {REASONING_MENU_LEVELS.filter((level) => reasoningLevels.includes(level)).map(
                    (level) => (
                      <SimplePickerOption
                        key={level}
                        label={REASONING_LABELS[level]}
                        selected={level === effectiveReasoning}
                        disabled={reasoningDisabled}
                        onSelect={() => {
                          onSelectReasoning(level);
                          close(true);
                        }}
                      />
                    ),
                  )}
                </SimplePickerPanel>
              ) : view === "provider" && activeRoute && activeChoice ? (
                <SimplePickerPanel title="Provider">
                  {providerRoutes.map((route) => (
                    <SimplePickerOption
                      key={route.route.id}
                      label={route.label}
                      selected={route.route.id === selectedRoute}
                      disabled={!route.route.active}
                      onSelect={() => {
                        onSelect(activeChoice.model.id, route.route.id);
                        close(true);
                      }}
                    />
                  ))}
                </SimplePickerPanel>
              ) : null}
            </div>,
            document.body,
          )
        : null}
    </div>
  );
}

function PickerInspector({
  activeView,
  modelLabel,
  effortLabel,
  providerLabel,
  onOpen,
}: {
  activeView: PickerView;
  modelLabel: string;
  effortLabel: string | null;
  providerLabel: string | null;
  onOpen: (view: Exclude<PickerView, "inspector">, trigger: HTMLButtonElement) => void;
}) {
  const rows: Array<{
    view: Exclude<PickerView, "inspector">;
    label: string;
    value: string;
  }> = [
    { view: "models", label: "Model", value: modelLabel },
    ...(effortLabel ? [{ view: "reasoning" as const, label: "Effort", value: effortLabel }] : []),
    ...(providerLabel
      ? [{ view: "provider" as const, label: "Provider", value: providerLabel }]
      : []),
  ];
  return (
    <div className="grid gap-0.5">
      {rows.map((row) => (
        <button
          key={row.view}
          type="button"
          role="menuitem"
          aria-haspopup="menu"
          aria-expanded={activeView === row.view}
          onClick={(event) => onOpen(row.view, event.currentTarget)}
          onPointerEnter={(event) => onOpen(row.view, event.currentTarget)}
          onKeyDown={(event) => {
            if (event.key !== "ArrowRight") return;
            event.preventDefault();
            event.stopPropagation();
            onOpen(row.view, event.currentTarget);
          }}
          className={cx(
            "flex h-7 w-full items-center gap-2 rounded-[4px] px-2 text-left text-[length:var(--fs-sm)] text-(--fg) transition-colors hover:bg-(--hover) focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-(--focus-ring)",
            activeView === row.view && "bg-(--hover)",
          )}
        >
          <span className="min-w-0 flex-1">{row.label}</span>
          <span className="max-w-[6rem] truncate text-[length:var(--fs-xs)] text-(--dim)">
            {row.value}
          </span>
          <ChevronRight className="h-3 w-3 shrink-0 text-(--dim)" />
        </button>
      ))}
    </div>
  );
}

function modelTriggerLabel(
  activeChoice: ModelChoice | null,
  selectedModel: string,
  loading: boolean,
  modelCount: number,
) {
  if (activeChoice) return activeChoice.label;
  if (loading) return "Loading…";
  return selectedModel || (modelCount ? "Select model" : "No models");
}

function handleModelPickerKeyDown(
  event: ReactKeyboardEvent<HTMLDivElement>,
  selectFirst: () => void,
) {
  if (event.key === "Enter" && event.target instanceof HTMLInputElement) {
    event.preventDefault();
    selectFirst();
    return;
  }
  if (event.key === "ArrowDown" && event.target instanceof HTMLInputElement) {
    event.preventDefault();
    event.currentTarget.querySelector<HTMLElement>('[role="menuitemradio"]')?.focus();
    return;
  }
  handleMenuKeyDown(event, () => undefined);
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
  if (!items.length) return;
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
