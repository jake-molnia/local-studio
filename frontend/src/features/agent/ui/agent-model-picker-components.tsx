"use client";

import {
  useCallback,
  useDeferredValue,
  useMemo,
  useState,
  type MouseEvent,
  type PointerEvent,
  type RefObject,
} from "react";
import Link from "next/link";
import { LegendList } from "@legendapp/list/react";
import { Check, ChevronDown, Search, Star } from "@/ui/icon-registry";
import { cx } from "@/ui/utils";
import { useMountSubscription } from "@/hooks/use-mount-subscription";
import {
  modelChoiceSearchText,
  routeForChoice,
  type ModelChoice,
  type ModelCompany,
  type ModelRoute,
} from "./agent-model-picker-data";

export function ModelPickerPanel({
  choices,
  companies,
  selectedCompany,
  onSelectCompany,
  query,
  onQueryChange,
  searchRef,
  selectedModel,
  defaultModel,
  onSelect,
  onSetDefault,
  activeRoute,
  onClose,
}: {
  choices: ModelChoice[];
  companies: ModelCompany[];
  selectedCompany: string;
  onSelectCompany: (company: string) => void;
  query: string;
  onQueryChange: (query: string) => void;
  searchRef: RefObject<HTMLInputElement | null>;
  selectedModel: string;
  defaultModel?: string;
  onSelect: (choice: ModelChoice) => void;
  onSetDefault?: (modelId: string, routeId: string) => void;
  activeRoute: ModelRoute | null;
  onClose: () => void;
}) {
  const [favorites, setFavorites] = useState<Set<string>>(() => new Set());
  useMountSubscription(() => {
    try {
      const stored = JSON.parse(
        window.localStorage.getItem("local-studio:model-favorites") ?? "[]",
      );
      if (Array.isArray(stored)) {
        setFavorites(new Set(stored.filter((value): value is string => typeof value === "string")));
      }
    } catch {
      setFavorites(new Set());
    }
  }, []);
  const updateFavorite = useCallback((modelId: string) => {
    setFavorites((current) => {
      const next = new Set(current);
      if (next.has(modelId)) next.delete(modelId);
      else next.add(modelId);
      window.localStorage.setItem("local-studio:model-favorites", JSON.stringify([...next]));
      return next;
    });
  }, []);
  const deferredQuery = useDeferredValue(query);
  const visibleChoices = useMemo(
    () => filteredChoices(choices, selectedCompany, deferredQuery, favorites),
    [choices, deferredQuery, favorites, selectedCompany],
  );
  const searching = query.trim().length > 0;
  const visibleCompanies = useMemo(
    () => (favorites.size ? [{ key: "favorites", label: "Favorites" }, ...companies] : companies),
    [companies, favorites.size],
  );
  const renderChoice = useCallback(
    ({ item: choice }: { item: ModelChoice }) => {
      const selected = choice.model.id === selectedModel;
      const preferredRoute = routeForChoice(choice, activeRoute);
      const isDefault = choice.model.id === defaultModel;
      const isFavorite = favorites.has(choice.model.id);
      return (
        <ModelChoiceRow
          choice={choice}
          selected={selected}
          showCompany={searching}
          isDefault={isDefault}
          isFavorite={isFavorite}
          disabled={!preferredRoute}
          onSelect={() => onSelect(choice)}
          onToggleFavorite={() => updateFavorite(choice.model.id)}
          onSetDefault={
            onSetDefault && preferredRoute
              ? () => onSetDefault(choice.model.id, preferredRoute.route.id)
              : undefined
          }
        />
      );
    },
    [
      activeRoute,
      defaultModel,
      favorites,
      onSelect,
      onSetDefault,
      searching,
      selectedModel,
      updateFavorite,
    ],
  );
  return (
    <div className="flex h-full min-h-0 overflow-hidden rounded-[calc(var(--rad-md)-1px)]">
      {!searching ? (
        <CompanySidebar
          companies={visibleCompanies}
          selectedCompany={selectedCompany}
          onSelectCompany={onSelectCompany}
        />
      ) : null}
      <div
        className={cx(
          "flex min-w-0 flex-1 flex-col overflow-hidden bg-(--color-popover)",
          !searching && "border-l border-(--border)",
        )}
      >
        <div className="px-2 pt-2">
          <div className="flex h-8 items-center gap-2 border-b border-(--border) pb-2 transition-colors focus-within:border-(--focus-ring)">
            <Search className="h-4 w-4 shrink-0 text-(--dim) opacity-70" />
            <input
              ref={searchRef}
              type="search"
              value={query}
              onChange={(event) => onQueryChange(event.target.value)}
              placeholder="Search models..."
              aria-label="Search models"
              className="h-6 min-w-0 flex-1 appearance-none !border-0 bg-transparent p-0 text-[length:var(--fs-sm)] leading-6 text-(--fg) !outline-none !ring-0 placeholder:text-(--dim) focus:!border-0 focus:!outline-none focus:!ring-0 focus-visible:!outline-none focus-visible:!ring-0"
            />
          </div>
        </div>
        <div className="min-h-0 flex-1 overflow-hidden">
          {visibleChoices.length ? (
            <LegendList
              data={visibleChoices}
              keyExtractor={(choice) => choice.key}
              renderItem={renderChoice}
              estimatedItemSize={40}
              className="h-full overscroll-contain p-1.5 pt-1 [scrollbar-gutter:stable]"
            />
          ) : (
            <div className="px-2 py-3 text-[length:var(--fs-xs)] text-(--dim)">
              <p>{query ? `No models match “${query}”.` : "No models are available."}</p>
              <Link
                href="/settings#models"
                onClick={onClose}
                className="mt-2 inline-flex h-7 items-center rounded-md bg-(--active) px-2 text-(--fg) hover:bg-(--hover)"
              >
                Open Models
              </Link>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

function CompanySidebar({
  companies,
  selectedCompany,
  onSelectCompany,
}: {
  companies: ModelCompany[];
  selectedCompany: string;
  onSelectCompany: (company: string) => void;
}) {
  const selectedIndex = Math.max(
    0,
    companies.findIndex((company) => company.key === selectedCompany),
  );
  return (
    <div className="w-11 shrink-0 overflow-hidden bg-(--color-panel-subtle)">
      <div
        role="tablist"
        aria-label="Model companies"
        className="relative flex h-full flex-col gap-1 overflow-y-auto overscroll-contain p-1 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden"
      >
        <span
          className="pointer-events-none absolute -right-0 top-3 z-10 h-5 w-[3px] rounded-l-full bg-(--accent) transition-transform duration-200 ease-out"
          style={{ transform: `translateY(${selectedIndex * 40}px)` }}
        />
        {companies.map((company) => {
          const selected = company.key === selectedCompany;
          return (
            <div key={company.key} className="relative w-full">
              <button
                type="button"
                role="tab"
                aria-selected={selected}
                aria-label={company.label}
                title={company.label}
                onClick={() => onSelectCompany(company.key)}
                className={cx(
                  "relative flex aspect-square w-full cursor-pointer items-center justify-center rounded-md text-(--dim) transition-colors hover:bg-(--hover) hover:text-(--fg) focus-visible:bg-(--hover) focus-visible:text-(--fg) focus-visible:outline-none",
                  selected && "bg-(--active) text-(--fg)",
                )}
              >
                <CompanyGlyph company={company} />
              </button>
            </div>
          );
        })}
      </div>
    </div>
  );
}

function CompanyGlyph({ company }: { company: ModelCompany }) {
  if (company.logo) {
    return (
      <img
        src={company.logo}
        alt=""
        className="h-5 w-5 rounded-[4px] object-contain grayscale contrast-125"
      />
    );
  }
  return (
    <span className="flex h-5 w-5 items-center justify-center rounded-[5px] border border-(--border) bg-(--color-input) text-[10px] font-semibold tracking-[-0.04em] text-(--fg)">
      {company.label.slice(0, 2)}
    </span>
  );
}

function ModelChoiceRow({
  choice,
  selected,
  showCompany,
  isDefault,
  isFavorite,
  disabled,
  onSelect,
  onSetDefault,
  onToggleFavorite,
}: {
  choice: ModelChoice;
  selected: boolean;
  showCompany: boolean;
  isDefault: boolean;
  isFavorite: boolean;
  disabled: boolean;
  onSelect: () => void;
  onSetDefault?: () => void;
  onToggleFavorite: () => void;
}) {
  return (
    <div
      className={cx(
        "group/model-choice relative flex min-h-10 w-full min-w-0 items-center rounded-md transition-[background-color,color] hover:bg-(--hover) focus-within:bg-(--hover)",
        selected && "bg-(--active)",
      )}
    >
      <button
        type="button"
        role="menuitemradio"
        aria-checked={selected}
        disabled={disabled}
        onClick={onSelect}
        className="flex min-h-10 min-w-0 flex-1 items-center gap-3 rounded-md px-2 text-left focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-inset focus-visible:ring-(--focus-ring) disabled:cursor-not-allowed disabled:opacity-45"
      >
        <div className="min-w-0 flex-1">
          <div className="truncate text-[length:var(--fs-xs)] font-medium leading-snug text-(--fg)">
            {choice.label}
          </div>
          {showCompany || disabled ? (
            <div className="mt-1 truncate text-[length:var(--fs-xs)] font-normal leading-snug text-(--dim)/70">
              {disabled ? "No connected route" : choice.company.label}
            </div>
          ) : null}
        </div>
      </button>
      {!disabled ? (
        <button
          type="button"
          onClick={(event) => {
            event.stopPropagation();
            onToggleFavorite();
          }}
          onKeyDown={(event) => event.stopPropagation()}
          aria-label={
            isFavorite ? `Remove ${choice.label} from favorites` : `Favorite ${choice.label}`
          }
          title={isFavorite ? "Remove favorite" : "Add favorite"}
          className={cx(
            "inline-flex h-6 w-6 shrink-0 items-center justify-center rounded-md text-(--dim) opacity-0 transition-[background-color,color,opacity] hover:bg-(--active) hover:text-(--fg) hover:opacity-100 focus-visible:opacity-100 focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-(--focus-ring) group-hover/model-choice:opacity-100",
            isFavorite && "text-amber-400 opacity-100",
          )}
        >
          <Star className={cx("h-3.5 w-3.5", isFavorite && "fill-current")} />
        </button>
      ) : null}
      {onSetDefault && !disabled ? (
        <button
          type="button"
          onClick={(event) => {
            event.stopPropagation();
            onSetDefault();
          }}
          onKeyDown={(event) => event.stopPropagation()}
          aria-label={
            isDefault ? `${choice.label} is the default model` : `Set ${choice.label} as default`
          }
          title={isDefault ? "Default model" : "Set as default"}
          className={cx(
            "mr-1 inline-flex h-6 w-6 shrink-0 items-center justify-center rounded-md text-(--dim) opacity-0 transition-[background-color,color,opacity] hover:bg-(--active) hover:text-(--fg) hover:opacity-100 focus-visible:opacity-100 focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-(--focus-ring) group-hover/model-choice:opacity-100",
            isDefault && "text-(--accent) opacity-100",
          )}
        >
          <Check className="h-3.5 w-3.5" />
        </button>
      ) : null}
    </div>
  );
}

export function SimplePickerPanel({
  title,
  children,
}: {
  title: string;
  children: React.ReactNode;
}) {
  return (
    <div>
      <div className="flex h-7 items-center border-b border-(--border) px-2 text-[length:var(--fs-xs)] font-medium text-(--dim)">
        {title}
      </div>
      <div className="grid gap-0.5 pt-1">{children}</div>
    </div>
  );
}

export function SimplePickerOption({
  label,
  selected,
  disabled,
  onSelect,
}: {
  label: string;
  selected: boolean;
  disabled: boolean;
  onSelect: () => void;
}) {
  return (
    <button
      type="button"
      role="menuitemradio"
      aria-checked={selected}
      disabled={disabled}
      onClick={onSelect}
      className={cx(
        "flex h-7 w-full items-center gap-2 rounded-[4px] px-2 text-left text-[length:var(--fs-sm)] text-(--fg) transition-colors hover:bg-(--hover) focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-(--focus-ring) disabled:opacity-45",
        selected && "bg-(--active)",
      )}
    >
      <span className="min-w-0 flex-1 truncate">{label}</span>
      {selected ? <Check className="h-3 w-3 shrink-0" /> : null}
    </button>
  );
}

export function ComposerPickerTrigger({
  label,
  title,
  company,
  disabled,
  open,
  notRunning,
  compact = false,
  onToggle,
}: {
  label: string;
  title: string;
  company?: ModelCompany;
  disabled: boolean;
  open: boolean;
  notRunning: boolean;
  compact?: boolean;
  onToggle: (event: MouseEvent<HTMLButtonElement>) => void;
}) {
  return (
    <button
      type="button"
      onPointerDown={stopToolbarEvent}
      onMouseDown={stopToolbarEvent}
      onClick={onToggle}
      disabled={disabled}
      className={cx(
        "group/model inline-flex !h-7 !min-h-7 !min-w-0 items-center justify-between gap-1.5 rounded-md bg-transparent px-1.5 text-[length:var(--fs-sm)] whitespace-nowrap text-(--fg)/78 transition-[background-color,color,transform] duration-[var(--motion-fast)] hover:bg-(--hover) hover:text-(--fg) active:scale-[0.98] active:bg-(--active) focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-(--focus-ring) disabled:opacity-60",
        compact ? "max-w-[8rem]" : "max-w-[12rem]",
        open && "bg-(--active) text-(--fg)",
      )}
      title={notRunning ? `${title} is not running` : title}
      aria-label={`${title}${notRunning ? " (not running)" : ""}`}
      aria-expanded={open}
      aria-haspopup="menu"
    >
      <span className="flex min-w-0 flex-1 items-center gap-1.5">
        {company ? <CompanyGlyph company={company} /> : null}
        <span className="min-w-0 truncate text-left text-(--fg)/90">{label}</span>
        {notRunning ? <span className="h-1.5 w-1.5 shrink-0 rounded-full bg-(--warn)" /> : null}
      </span>
      <ChevronDown className="pointer-events-none h-3 w-3 shrink-0 text-(--dim)" />
    </button>
  );
}

export function filteredChoices(
  choices: ModelChoice[],
  selectedCompany: string,
  query: string,
  favorites: ReadonlySet<string> = new Set(),
) {
  const normalized = query.trim().toLocaleLowerCase();
  if (normalized) {
    const tokens = normalized.split(/\s+/).filter(Boolean);
    return choices
      .flatMap((choice) => {
        const text = modelChoiceSearchText(choice);
        let score = favorites.has(choice.model.id) ? 1000 : 0;
        for (const token of tokens) {
          const index = text.indexOf(token);
          if (index < 0) return [];
          score += index === 0 ? 100 : Math.max(1, 50 - index);
        }
        return [{ choice, score }];
      })
      .toSorted(
        (left, right) =>
          right.score - left.score || left.choice.label.localeCompare(right.choice.label),
      )
      .map(({ choice }) => choice);
  }
  if (selectedCompany === "favorites")
    return choices.filter((choice) => favorites.has(choice.model.id));
  return choices.filter((choice) => choice.company.key === selectedCompany);
}

export function stopToolbarEvent(event: MouseEvent | PointerEvent) {
  event.stopPropagation();
}
