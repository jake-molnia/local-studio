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

type PickerView = "models" | "reasoning" | "provider";

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
  const [view, setView] = useState<PickerView>("models");
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
      setQuery("");
      if (restoreFocus) requestAnimationFrame(() => activeTriggerRef.current?.focus());
    },
    [updateOpen],
  );

  const openView = useCallback(
    (nextView: PickerView, trigger: HTMLButtonElement, pointer: boolean) => {
      setOpenSource(pointer ? "pointer" : "keyboard");
      activeTriggerRef.current = trigger;
      if (open && view === nextView) {
        close();
        return;
      }
      if (nextView === "models") {
        setSelectedCompany(activeChoice?.company.key ?? companies[0]?.key ?? "local");
        setQuery("");
      }
      setView(nextView);
      updateOpen(true);
    },
    [activeChoice?.company.key, close, companies, open, updateOpen, view],
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
    if (!open) return;
    const onPointerDown = (event: globalThis.PointerEvent) => {
      if (!(event.target instanceof Node)) return;
      if (anchorRef.current?.contains(event.target) || panelRef.current?.contains(event.target)) {
        return;
      }
      close();
    };
    const onKeyDown = (event: globalThis.KeyboardEvent) => {
      if (event.key !== "Escape") return;
      event.preventDefault();
      close(true);
    };
    document.addEventListener("pointerdown", onPointerDown, true);
    document.addEventListener("keydown", onKeyDown);
    return () => {
      document.removeEventListener("pointerdown", onPointerDown, true);
      document.removeEventListener("keydown", onKeyDown);
    };
  }, [close, open]);

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
      } else if (openSource === "keyboard") {
        panelRef.current?.querySelector<HTMLElement>('[role^="menuitem"]:not(:disabled)')?.focus();
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
        title={`Model: ${activeChoice?.label || selectedModel || "No models"}`}
        company={activeChoice?.company}
        disabled={loading}
        open={open && view === "models"}
        notRunning={selectedModelNotRunning}
        onToggle={(event) => openView("models", event.currentTarget, event.detail > 0)}
      />
      {supportsReasoning ? (
        <ComposerPickerTrigger
          label={REASONING_LABELS[effectiveReasoning]}
          title={`Effort: ${REASONING_LABELS[effectiveReasoning]}`}
          disabled={loading || reasoningDisabled}
          open={open && view === "reasoning"}
          notRunning={false}
          compact
          onToggle={(event) => openView("reasoning", event.currentTarget, event.detail > 0)}
        />
      ) : null}
      {supportsProviderSelection && activeRoute ? (
        <ComposerPickerTrigger
          label={activeRoute.label}
          title={`Provider: ${activeRoute.label}`}
          disabled={loading}
          open={open && view === "provider"}
          notRunning={false}
          compact
          onToggle={(event) => openView("provider", event.currentTarget, event.detail > 0)}
        />
      ) : null}
      {present && typeof document !== "undefined"
        ? createPortal(
            <div
              ref={placePanel}
              className={cx(
                `composer-popover fixed z-[300] max-w-[calc(100vw-1rem)] ${POPOVER_SURFACE_CLASS}`,
                open ? "composer-popover-enter" : "composer-popover-exit pointer-events-none",
                view === "models"
                  ? "h-[min(21.625rem,calc(100vh-1rem))] w-[22.5rem] overflow-hidden p-0"
                  : "w-[11rem] overflow-hidden p-1",
              )}
              aria-hidden={!open}
              data-open-source={openSource}
              data-model-picker-content
              onKeyDown={(event) => {
                setOpenSource("keyboard");
                if (view === "models") {
                  handleModelPickerKeyDown(event, () => {
                    const first = filteredChoices(choices, selectedCompany, query)[0];
                    if (first) selectChoice(first);
                  });
                  return;
                }
                handleMenuKeyDown(event, () => close(true));
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
