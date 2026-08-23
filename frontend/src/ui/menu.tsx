import type { ComponentType, KeyboardEvent, ReactNode } from "react";

type MenuItemIcon = ComponentType<{ className?: string; strokeWidth?: number }>;

export type MenuItemProps = {
  Icon?: MenuItemIcon;
  danger?: boolean;
  disabled?: boolean;
  onClick: () => void;
  children: ReactNode;
};

export function MenuItem({
  Icon,
  danger = false,
  disabled = false,
  onClick,
  children,
}: MenuItemProps) {
  return (
    <button
      type="button"
      role="menuitem"
      data-ui-control="button"
      onClick={onClick}
      disabled={disabled}
      className={
        Icon
          ? `flex h-6 w-full items-center gap-1.5 rounded-[4px] px-1.5 text-left text-[length:var(--fs-xs)] transition-[color,background-color] ${
              danger
                ? "text-(--err) hover:bg-(--err)/10 active:bg-(--err)/15"
                : "text-(--fg) hover:bg-(--color-menu-hover) active:bg-(--color-selected)"
            } disabled:cursor-default disabled:opacity-40 disabled:hover:bg-transparent`
          : "flex h-6 w-full items-center rounded-[4px] px-1.5 text-left text-[length:var(--fs-xs)] text-(--fg) transition-[color,background-color] hover:bg-(--color-menu-hover) active:bg-(--color-selected) disabled:cursor-default disabled:opacity-40 disabled:hover:bg-transparent"
      }
    >
      {Icon ? (
        <Icon className={`h-3 w-3 shrink-0 ${danger ? "" : "opacity-70"}`} strokeWidth={1.5} />
      ) : null}
      {Icon ? <span className="truncate">{children}</span> : children}
    </button>
  );
}

export function handleMenuKeyboard(event: KeyboardEvent<HTMLElement>) {
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
