"use client";

import { createPortal } from "react-dom";
import { ProgressBar, Spinner } from "@/ui";
import { POPOVER_SURFACE_CLASS } from "@/ui/popover";
import type { ProjectImportProgress } from "@/features/agent/projects/api";

export type ProjectImportToastState =
  | ProjectImportProgress
  | { stage: "complete"; message: string; progress: 100 }
  | { stage: "error"; message: string; progress: 100 };

const STAGE_LABELS: Record<ProjectImportToastState["stage"], string> = {
  preparing: "Preparing repository",
  creating: "Preparing repository",
  uploading: "Uploading to code.storage",
  saving: "Finishing sync",
  complete: "Repository synced",
  error: "Sync failed",
};

export function ProjectImportToast({
  state,
  onDismiss,
}: {
  state: ProjectImportToastState | null;
  onDismiss: () => void;
}) {
  if (!state) return null;
  const active = state.stage !== "complete" && state.stage !== "error";
  const toast = (
    <div
      role={state.stage === "error" ? "alert" : "status"}
      aria-live="polite"
      className={`fixed bottom-5 right-5 z-[1400] w-[min(340px,calc(100vw-24px))] px-3 py-3 ${POPOVER_SURFACE_CLASS}`}
    >
      <div className="flex items-start gap-2.5">
        {active ? <Spinner size="sm" className="mt-0.5 shrink-0 text-(--link)" /> : null}
        <div className="min-w-0 flex-1">
          <div
            className={`text-[length:var(--fs-xs)] font-medium ${state.stage === "error" ? "text-(--err)" : state.stage === "complete" ? "text-(--hl2)" : "text-(--fg)"}`}
          >
            {STAGE_LABELS[state.stage]}
          </div>
          <div className="mt-0.5 text-[length:var(--fs-xs)] leading-4 text-(--dim)">
            {state.message}
          </div>
        </div>
        {!active ? (
          <button
            type="button"
            onClick={onDismiss}
            aria-label="Dismiss repository sync status"
            className="flex h-5 w-5 shrink-0 items-center justify-center rounded text-(--dim) hover:bg-(--hover) hover:text-(--fg)"
          >
            ×
          </button>
        ) : null}
      </div>
      <ProgressBar
        progress={state.progress}
        className="mt-2.5"
        barClassName={state.stage === "error" ? "bg-(--err)/70" : "bg-(--link)/70"}
      />
    </div>
  );
  return typeof document === "undefined" ? null : createPortal(toast, document.body);
}
