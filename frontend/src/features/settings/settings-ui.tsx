"use client";

import Link from "next/link";
import { useMemo, useState, type ReactNode } from "react";
import {
  AppPage,
  Button,
  buttonClasses,
  Input,
  RefreshIconButton,
  SearchInput,
  SectionNav,
  StatusPill,
  type SectionNavItem,
  type UiTone,
} from "@/ui";
import { ChevronDown, ChevronLeft, SettingsIcon } from "@/ui/icon-registry";
import { cx } from "@/ui/utils";
import { ProfileAvatar, useLocalProfile } from "@/features/shell/local-profile";

export type SettingsSectionId = string;
export type SettingsSearchEntry = {
  label: string;
  target?: string;
  terms?: readonly string[];
};
export type SettingsSectionDef<Id extends SettingsSectionId = SettingsSectionId> =
  SectionNavItem<Id> & {
    searchTerms?: readonly string[];
    settings?: readonly SettingsSearchEntry[];
  };

type LayoutProps<Id extends SettingsSectionId = SettingsSectionId> = {
  sections: SettingsSectionDef<Id>[];
  activeSection: Id;
  title: string;
  status?: ReactNode;
  loading: boolean;
  onReload: () => void;
  onSelectSection: (section: Id) => void;
  eyebrow?: string;
  refreshLabel?: string;
  showRefresh?: boolean;
  width?: "default" | "wide";
  takeover?: boolean;
  children: ReactNode;
};

type RowProps = {
  label: string;
  description?: ReactNode;
  value?: ReactNode;
  control?: ReactNode;
  status?: ReactNode;
  actions?: ReactNode;
  children?: ReactNode;
};

function settingsSearchKey(value: string): string {
  return value
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-");
}

export function SettingsLayout<Id extends SettingsSectionId = SettingsSectionId>({
  sections,
  activeSection,
  title,
  status,
  loading,
  onReload,
  onSelectSection,
  eyebrow,
  refreshLabel = `Refresh ${title.toLowerCase()}`,
  showRefresh = true,
  width = "default",
  takeover = false,
  children,
}: LayoutProps<Id>) {
  const [navigationQuery, setNavigationQuery] = useState("");
  const active = sections.find((section) => section.id === activeSection);
  const searchResults = useMemo(() => {
    const query = navigationQuery.trim().toLowerCase();
    if (!query) return [];
    return sections.flatMap((section) => {
      const entries = section.settings ?? [];
      const matches = entries.filter((entry) =>
        `${entry.label} ${entry.terms?.join(" ") ?? ""}`.toLowerCase().includes(query),
      );
      const sectionMatches =
        `${section.label} ${section.description} ${section.searchTerms?.join(" ") ?? ""}`
          .toLowerCase()
          .includes(query);
      return [
        ...(sectionMatches && matches.length === 0
          ? [{ section, entry: { label: section.label } }]
          : []),
        ...matches.map((entry) => ({ section, entry })),
      ];
    });
  }, [navigationQuery, sections]);
  const updateNavigationQuery = (value: string) => {
    setNavigationQuery(value);
    const query = value.trim().toLowerCase();
    if (!query) return;
    const match = sections.find((section) => {
      const sectionText = `${section.label} ${section.description} ${section.searchTerms?.join(" ") ?? ""}`;
      const settingsText = (section.settings ?? [])
        .map((entry) => `${entry.label} ${entry.terms?.join(" ") ?? ""}`)
        .join(" ");
      return `${sectionText} ${settingsText}`.toLowerCase().includes(query);
    });
    if (match && match.id !== activeSection) onSelectSection(match.id);
  };
  const layoutWidth =
    width === "wide"
      ? "max-w-[82rem] lg:grid-cols-[136px_minmax(0,68rem)]"
      : "max-w-[44rem] lg:grid-cols-[136px_minmax(0,32rem)]";

  const selectSearchResult = (section: Id, target?: string) => {
    onSelectSection(section);
    if (!target) return;
    requestAnimationFrame(() => {
      requestAnimationFrame(() => {
        const element = document.querySelector<HTMLElement>(
          `[data-setting-key="${settingsSearchKey(target)}"]`,
        );
        element?.scrollIntoView({ block: "center" });
        element?.focus({ preventScroll: true });
      });
    });
  };
  const navigation = navigationQuery.trim() ? (
    searchResults.length ? (
      <div role="listbox" aria-label="Matching settings" className="flex flex-col gap-px">
        {searchResults.map(({ section, entry }) => (
          <button
            key={`${section.id}:${entry.label}`}
            type="button"
            role="option"
            aria-selected={section.id === activeSection}
            onClick={() => selectSearchResult(section.id, entry.target ?? entry.label)}
            className="flex h-6 w-full items-center gap-1.5 rounded-[4px] px-2 text-left text-[length:var(--fs-xs)] text-(--ui-muted) transition-colors hover:bg-(--ui-hover) hover:text-(--ui-fg)"
          >
            <span className="flex h-3.5 w-3.5 shrink-0 items-center justify-center opacity-70">
              {section.icon}
            </span>
            <span className="min-w-0 truncate">
              {section.label === entry.label ? section.label : `${section.label} › ${entry.label}`}
            </span>
          </button>
        ))}
      </div>
    ) : (
      <div className="px-2 py-2 text-[length:var(--fs-xs)] text-(--ui-muted)">
        No settings found
      </div>
    )
  ) : (
    <SectionNav
      label={`${title} sections`}
      items={sections}
      activeItem={activeSection}
      onSelectItem={onSelectSection}
    />
  );
  const content = (
    <>
      <header className="mb-3 flex min-h-7 items-start justify-between gap-3">
        <div className="min-w-0">
          {eyebrow ? (
            <div className="mb-0.5 text-[length:var(--fs-xs)] text-(--ui-muted)">{eyebrow}</div>
          ) : null}
          <h2 className="text-[length:var(--fs-md)] font-medium tracking-[-0.015em] text-(--ui-fg)">
            {active?.label ?? title}
          </h2>
          {!takeover && active?.description ? (
            <p className="mt-0.5 max-w-[30rem] text-[length:var(--fs-xs)] leading-relaxed text-(--ui-muted)">
              {active.description}
            </p>
          ) : null}
        </div>
        {!takeover && (status || showRefresh) ? (
          <div className="flex shrink-0 items-center gap-2 text-[length:var(--fs-xs)] text-(--ui-muted)">
            {status}
            {showRefresh ? (
              <RefreshIconButton onClick={onReload} loading={loading} label={refreshLabel} />
            ) : null}
          </div>
        ) : null}
      </header>
      <div>{children}</div>
    </>
  );

  if (takeover) {
    return (
      <AppPage className="overflow-hidden">
        <div className="grid h-full min-h-0 grid-cols-1 lg:grid-cols-[194px_minmax(0,1fr)]">
          <aside className="hidden min-h-0 flex-col border-r border-(--ui-separator) bg-(--sidebar-bg) lg:flex">
            <div className="flex h-9 shrink-0 items-center px-2">
              <Link
                href="/agent"
                className="inline-flex h-6 items-center gap-1 rounded-[4px] px-1.5 text-[length:var(--fs-xs)] text-(--ui-muted) transition-colors hover:bg-(--ui-hover) hover:text-(--ui-fg)"
              >
                <ChevronLeft className="h-3 w-3" />
                Back
              </Link>
            </div>
            <div className="px-1.5 pb-1.5">
              <SearchInput
                value={navigationQuery}
                onChange={updateNavigationQuery}
                placeholder="Search Settings"
                aria-label="Search Settings"
                className="[&_input]:h-7 [&_input]:rounded-[4px] [&_input]:bg-(--ui-surface)"
              />
            </div>
            <div className="min-h-0 flex-1 overflow-y-auto px-1.5">{navigation}</div>
            <SettingsTakeoverFooter loading={loading} onReload={onReload} />
          </aside>
          <section className="min-h-0 min-w-0 overflow-y-auto">
            <div className="border-b border-(--ui-separator) px-3 py-2 lg:hidden">
              <div className="mb-2 flex items-center justify-between gap-2">
                <Link
                  href="/agent"
                  className="inline-flex h-7 items-center gap-1 rounded-[4px] px-1.5 text-[length:var(--fs-xs)] text-(--ui-muted)"
                >
                  <ChevronLeft className="h-3 w-3" />
                  Back
                </Link>
                <span className="text-[length:var(--fs-sm)] font-medium">{title}</span>
              </div>
              <SearchInput
                value={navigationQuery}
                onChange={updateNavigationQuery}
                placeholder="Search Settings"
                aria-label="Search Settings"
                className="mb-2 [&_input]:h-7 [&_input]:rounded-[4px] [&_input]:bg-(--ui-surface)"
              />
              <div className="overflow-x-auto [&_nav>div]:flex-nowrap [&_nav_button]:max-w-none [&_nav_button]:shrink-0">
                {navigation}
              </div>
            </div>
            <div className="mx-auto w-full max-w-[32rem] px-4 pb-12 pt-5 sm:px-6 lg:pt-7">
              {content}
            </div>
          </section>
        </div>
      </AppPage>
    );
  }

  return (
    <AppPage>
      <div
        className={cx(
          "mx-auto grid w-full grid-cols-1 gap-3 px-3 py-3 sm:px-4 lg:justify-center lg:gap-3 lg:py-5",
          layoutWidth,
        )}
      >
        <aside className="min-w-0 lg:sticky lg:top-5 lg:self-start">
          <div className="mb-2 hidden items-center justify-between gap-2 px-1 lg:flex">
            <h1 className="text-[length:var(--fs-sm)] font-medium tracking-[-0.01em] text-(--ui-fg)">
              {title}
            </h1>
            {showRefresh ? (
              <RefreshIconButton onClick={onReload} loading={loading} label={refreshLabel} />
            ) : null}
          </div>
          {navigation}
        </aside>
        <section className="min-w-0 pb-10">{content}</section>
      </div>
    </AppPage>
  );
}

function SettingsTakeoverFooter({ loading, onReload }: { loading: boolean; onReload: () => void }) {
  const [profile] = useLocalProfile();
  return (
    <div className="flex h-9 shrink-0 items-center gap-0.5 border-t border-(--ui-separator)/70 px-1.5">
      <Link
        href="/settings#profile"
        className="flex min-w-0 flex-1 items-center gap-1.5 rounded-[4px] px-1.5 py-1 transition-colors hover:bg-(--ui-hover)"
      >
        <ProfileAvatar profile={profile} />
        <span className="truncate text-[length:var(--fs-xs)] text-(--ui-fg)">{profile.name}</span>
      </Link>
      <RefreshIconButton onClick={onReload} loading={loading} label="Refresh settings" />
      <Link
        href="/agent"
        aria-label="Close Settings"
        title="Close Settings"
        className="flex h-6 w-6 items-center justify-center rounded-[4px] bg-(--ui-active) text-(--ui-fg) transition-colors hover:bg-(--ui-hover)"
      >
        <SettingsIcon className="h-3 w-3" />
      </Link>
    </div>
  );
}

export function SettingsGroup({
  title,
  description,
  actions,
  children,
  collapsible,
  defaultOpen,
}: {
  title: string;
  description?: string;
  actions?: ReactNode;
  children: ReactNode;
  collapsible?: boolean;
  defaultOpen?: boolean;
}) {
  const [open, setOpen] = useState(defaultOpen ?? true);
  const showBody = collapsible ? open : true;

  return (
    <section
      data-setting-key={settingsSearchKey(title)}
      tabIndex={-1}
      className="mb-4 rounded-[6px] outline-none transition-colors focus:bg-(--ui-hover)/30 last:mb-0"
    >
      <div className="mb-1.5 flex items-start justify-between gap-3 px-1">
        <div className="min-w-0">
          {collapsible ? (
            <button
              type="button"
              onClick={() => setOpen((value) => !value)}
              aria-expanded={open}
              className="group flex items-center gap-1.5 text-(--ui-fg)"
            >
              <ChevronDown
                className={cx(
                  "h-3.5 w-3.5 text-(--ui-muted) transition-transform",
                  open ? "" : "-rotate-90",
                )}
                aria-hidden
              />
              <h3 className="text-[length:var(--fs-xs)] font-medium tracking-[-0.01em]">{title}</h3>
            </button>
          ) : (
            <h3 className="text-[length:var(--fs-xs)] font-medium tracking-[-0.01em] text-(--ui-fg)">
              {title}
            </h3>
          )}
          {description ? (
            <p className="mt-0.5 text-[length:var(--fs-2xs)] leading-[1.4] text-(--ui-muted)">
              {description}
            </p>
          ) : null}
        </div>
        {actions ? <div className="shrink-0">{actions}</div> : null}
      </div>
      {showBody ? (
        <div className="overflow-hidden rounded-[6px] border border-(--ui-separator) bg-(--ui-surface)/45 [&>*+*]:border-t [&>*+*]:border-(--ui-separator)/80">
          {children}
        </div>
      ) : null}
    </section>
  );
}

export function SettingsRow({
  label,
  description,
  value,
  control,
  status,
  actions,
  children,
}: RowProps) {
  const primaryValue = control ?? value;

  return (
    <div
      data-setting-key={settingsSearchKey(label)}
      tabIndex={-1}
      className="px-3 py-1.5 outline-none transition-colors hover:bg-(--ui-hover)/35 focus:bg-(--ui-hover)/45"
    >
      <div className="grid min-h-7 grid-cols-1 gap-1 md:grid-cols-[minmax(160px,0.3fr)_minmax(0,1fr)] md:items-center md:gap-3">
        <div className="min-w-0">
          <div
            className="truncate text-[length:var(--fs-xs)] font-medium text-(--ui-fg)"
            title={label}
          >
            {label}
          </div>
          {description ? (
            <div className="mt-0.5 text-[length:var(--fs-2xs)] leading-[1.4] text-(--ui-muted)">
              {description}
            </div>
          ) : null}
        </div>
        <div className="flex min-w-0 items-center justify-end gap-2">
          {primaryValue ? (
            <div className={control ? "min-w-0 shrink-0" : "min-w-0 flex-1"}>{primaryValue}</div>
          ) : null}
          {status ? <div className="shrink-0">{status}</div> : null}
          {actions ? <div className="flex shrink-0 items-center gap-1.5">{actions}</div> : null}
        </div>
      </div>
      {children ? (
        <div className="mt-1.5 grid grid-cols-1 gap-1 md:grid-cols-[minmax(160px,0.3fr)_minmax(0,1fr)] md:gap-3">
          <div className="hidden md:block" />
          <div className="min-w-0">{children}</div>
        </div>
      ) : null}
    </div>
  );
}

export function SettingsValue({
  children,
  mono = false,
  dim = false,
  truncate = false,
  wrap = false,
}: {
  children: ReactNode;
  mono?: boolean;
  dim?: boolean;
  truncate?: boolean;
  wrap?: boolean;
}) {
  const value =
    children === null || children === undefined || children === "" ? "Not set" : children;
  return (
    <div
      className={cx(
        "text-[length:var(--fs-sm)]",
        mono ? "font-mono text-[length:var(--fs-xs)]" : "",
        dim ? "text-(--ui-muted)" : "text-(--ui-fg)/80",
        truncate ? "min-w-0 truncate" : "",
        wrap && !truncate ? "min-w-0 whitespace-normal break-words [overflow-wrap:anywhere]" : "",
      )}
      title={typeof children === "string" ? children : undefined}
    >
      {value}
    </div>
  );
}

export type SettingsFactRow = {
  label: string;
  value: ReactNode;
  key?: string | number;
  description?: ReactNode;
  mono?: boolean;
  dim?: boolean;
  truncate?: boolean;
  wrap?: boolean;
  status?: { label: ReactNode; tone?: UiTone };
  actions?: ReactNode;
  children?: ReactNode;
};

export function SettingsFactRows({ rows }: { rows: SettingsFactRow[] }) {
  return (
    <>
      {rows.map((row) => (
        <SettingsRow
          key={row.key ?? row.label}
          label={row.label}
          description={row.description}
          value={
            <SettingsValue mono={row.mono} dim={row.dim} truncate={row.truncate} wrap={row.wrap}>
              {row.value}
            </SettingsValue>
          }
          status={
            row.status ? (
              <StatusPill tone={row.status.tone}>{row.status.label}</StatusPill>
            ) : undefined
          }
          actions={row.actions}
        >
          {row.children}
        </SettingsRow>
      ))}
    </>
  );
}

export function SettingsButton({
  children,
  onClick,
  disabled,
  title,
  tone = "default",
  type = "button",
  "aria-label": ariaLabel,
}: {
  children: ReactNode;
  onClick?: () => void;
  disabled?: boolean;
  title?: string;
  tone?: "default" | "primary" | "danger";
  type?: "button" | "submit";
  "aria-label"?: string;
}) {
  return (
    <Button
      type={type}
      onClick={onClick}
      disabled={disabled}
      title={title}
      aria-label={ariaLabel}
      size="sm"
      variant={tone === "primary" ? "primary" : tone === "danger" ? "danger" : "secondary"}
    >
      {children}
    </Button>
  );
}

export function SettingsLink({
  href,
  children,
  tone = "default",
  "aria-label": ariaLabel,
}: {
  href: string;
  children: ReactNode;
  tone?: "default" | "primary" | "danger";
  "aria-label"?: string;
}) {
  return (
    <a
      href={href}
      target="_blank"
      rel="noopener noreferrer"
      aria-label={ariaLabel}
      style={
        tone === "primary"
          ? { color: "var(--color-primary-foreground)" }
          : tone === "danger"
            ? { color: "var(--destructive-foreground)" }
            : undefined
      }
      className={buttonClasses(
        tone === "primary" ? "primary" : tone === "danger" ? "danger" : "secondary",
        "sm",
      )}
    >
      {children}
    </a>
  );
}

const noticeClasses: Record<UiTone, string> = {
  default: "border-(--ui-border) bg-(--ui-hover)/40 text-(--ui-muted)",
  good: "border-(--ui-success)/30 bg-(--ui-success)/10 text-(--ui-success)",
  warning: "border-(--ui-warning)/30 bg-(--ui-warning)/10 text-(--ui-warning)",
  danger: "border-(--ui-danger)/30 bg-(--ui-danger)/10 text-(--ui-danger)",
  info: "border-(--ui-info)/30 bg-(--ui-info)/10 text-(--ui-info)",
};

export function SettingsNotice({
  children,
  tone = "info",
  className,
}: {
  children: ReactNode;
  tone?: UiTone;
  className?: string;
}) {
  return (
    <div
      className={cx(
        "rounded-md border px-3 py-2 text-[length:var(--fs-sm)] leading-relaxed",
        noticeClasses[tone],
        className,
      )}
    >
      {children}
    </div>
  );
}

export function SettingsInput({
  id,
  value,
  onChange,
  onBlur,
  placeholder,
  type = "text",
  className = "",
  "aria-label": ariaLabel,
}: {
  id?: string;
  value: string;
  onChange: (value: string) => void;
  onBlur?: () => void;
  placeholder?: string;
  type?: "text" | "password";
  className?: string;
  "aria-label"?: string;
}) {
  return (
    <Input
      id={id}
      type={type}
      value={value}
      onChange={(event) => onChange(event.target.value)}
      onBlur={onBlur}
      placeholder={placeholder}
      aria-label={ariaLabel}
      className={cx("h-7", className)}
    />
  );
}

export { StatusPill };
