"use client";

import type { ReactNode } from "react";

type TabVariant = "underline" | "pill" | "button-group";

interface TabItem<T extends string = string> {
  id: T;
  label: string;
  icon?: ReactNode;
}

interface TabsProps<T extends string = string> {
  variant?: TabVariant;
  items: TabItem<T>[];
  activeTab: T;
  onSelectTab: (tab: T) => void;
  className?: string;
}

function Tabs<T extends string = string>({
  variant = "underline",
  items,
  activeTab,
  onSelectTab,
  className = "",
}: TabsProps<T>) {
  if (variant === "underline") {
    return (
      // overflow-x-auto + shrink-0: the labels are nowrap, so without these the
      // flex row shrinks them past their content width and they overlap into
      // unreadable text once the strip is wider than a phone.
      <div role="tablist" className={`flex gap-0 overflow-x-auto ${className}`}>
        {items.map((tab) => (
          <button
            key={tab.id}
            type="button"
            data-ui-control="compact"
            role="tab"
            aria-selected={activeTab === tab.id}
            onClick={() => onSelectTab(tab.id)}
            // inline-flex, not inline: the icons render as block-level SVGs, so
            // an `inline` wrapper dropped them onto their own line above the
            // label instead of sitting beside it.
            className={`inline-flex h-9 shrink-0 items-center gap-1.5 whitespace-nowrap px-3 text-[length:var(--fs-md)] font-medium transition-[color,background-color,border-color] border-b-2 ${
              activeTab === tab.id
                ? "border-(--ui-accent) text-(--ui-fg)"
                : "border-transparent text-(--ui-muted) hover:text-(--ui-fg)"
            }`}
          >
            {tab.icon ? <span className="flex shrink-0 items-center">{tab.icon}</span> : null}
            <span>{tab.label}</span>
          </button>
        ))}
      </div>
    );
  }

  if (variant === "pill") {
    return (
      <div role="tablist" className={`flex gap-0 overflow-x-auto ${className}`}>
        {items.map((tab) => (
          <button
            key={tab.id}
            type="button"
            data-ui-control="compact"
            role="tab"
            aria-selected={activeTab === tab.id}
            onClick={() => onSelectTab(tab.id)}
            className={`flex h-8 items-center gap-1.5 rounded-[var(--rad-sm)] px-2.5 text-[length:var(--fs-md)] whitespace-nowrap transition-colors ${
              activeTab === tab.id
                ? "bg-(--active) font-medium text-(--fg)"
                : "text-(--color-foreground-subtle) hover:bg-(--hover) hover:text-(--fg)"
            }`}
          >
            {tab.icon}
            <span>{tab.label}</span>
          </button>
        ))}
      </div>
    );
  }

  // button-group
  return (
    <div className={`overflow-x-auto ${className}`}>
      <div className="flex min-w-max items-center gap-0.5 rounded-[var(--rad-md)] border border-(--ui-border) bg-(--surface-3) p-1">
        {items.map((tab) => (
          <button
            key={tab.id}
            type="button"
            data-ui-control="compact"
            role="tab"
            aria-selected={activeTab === tab.id}
            onClick={() => onSelectTab(tab.id)}
            className={`flex h-7 items-center gap-1.5 rounded-[var(--rad-sm)] px-3 transition-colors text-[length:var(--fs-sm)] whitespace-nowrap border ${
              activeTab === tab.id
                ? "border-transparent bg-(--active) text-(--ui-fg)"
                : "border-transparent text-(--ui-muted) hover:border-(--ui-border) hover:text-(--ui-fg)"
            }`}
          >
            {tab.icon}
            <span>{tab.label}</span>
          </button>
        ))}
      </div>
    </div>
  );
}

export { Tabs };
export type { TabsProps, TabItem, TabVariant };
