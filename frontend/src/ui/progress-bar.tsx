"use client";

import { cx } from "./utils";

export function ProgressBar({
  progress,
  className,
  trackClassName,
  barClassName,
}: {
  progress: number | null;
  className?: string;
  trackClassName?: string;
  barClassName?: string;
}) {
  const pct = progress === null ? null : Math.min(100, Math.max(0, progress));
  return (
    <div
      role="progressbar"
      aria-valuemin={0}
      aria-valuemax={100}
      aria-valuenow={pct ?? undefined}
      className={cx(
        "h-1 w-full overflow-hidden rounded-full bg-(--ui-fg)/15",
        className,
        trackClassName,
      )}
    >
      <div
        className={cx(
          "h-full rounded-full bg-(--ui-fg)/40 transition-all duration-300",
          pct === null && "origin-left animate-pulse",
          barClassName,
        )}
        style={{ width: pct === null ? "40%" : `${pct}%` }}
      />
    </div>
  );
}
