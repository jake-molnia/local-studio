"use client";

import type { ReactNode, RefObject } from "react";
import { Spinner } from "@/ui";
import { ArrowUp, Plus } from "@/ui/icon-registry";
import { StopIcon } from "@/ui/icons";

export function AgentComposerActions({
  fileInputRef,
  onAttachFiles,
  readingAttachments,
  running,
  status,
  input,
  attachmentsCount,
  onAbortTurn,
  onOpenContext,
  contextOpen,
  modelSelector,
}: {
  fileInputRef: RefObject<HTMLInputElement | null>;
  onAttachFiles: (files: FileList | null) => void;
  readingAttachments: boolean;
  running: boolean;
  status?: string;
  input: string;
  attachmentsCount: number;
  onAbortTurn: () => void;
  onOpenContext: () => void;
  contextOpen: boolean;
  modelSelector?: ReactNode;
}) {
  const inputHasText = Boolean(input.trim());
  const starting = status === "starting";
  const stopping = status === "stopping";

  return (
    <div className="agent-composer-actions-row flex min-h-8 items-center gap-0.5 bg-transparent px-1.5 pb-1.5 pt-0 text-xs">
      <input
        ref={fileInputRef}
        type="file"
        multiple
        className="hidden"
        onChange={(event) => onAttachFiles(event.currentTarget.files)}
      />
      <button
        type="button"
        onClick={onOpenContext}
        disabled={readingAttachments}
        data-composer-context-trigger
        aria-expanded={contextOpen}
        className={`inline-flex !h-7 !min-h-7 !w-7 !min-w-7 shrink-0 items-center justify-center rounded-full hover:bg-(--hover) hover:text-(--fg) disabled:opacity-30 ${
          contextOpen ? "bg-(--active) text-(--fg)" : "text-(--hl2)"
        }`}
        aria-label="Add context"
        title="Add context"
      >
        <Plus className="h-4 w-4" strokeWidth={1.75} />
      </button>
      <div className="ml-auto flex min-w-0 shrink items-center gap-0.5">
        {modelSelector}
        {running ? (
          <>
            {starting || stopping ? (
              <span
                className="inline-flex !h-7 !min-h-7 shrink-0 items-center gap-1.5 px-2 text-[length:var(--fs-sm)] text-(--dim)"
                title={stopping ? "Waiting for Pi to stop" : "Waiting for the model to start"}
              >
                <Spinner size="xs" />
                {stopping ? "Stopping…" : "Starting…"}
              </span>
            ) : inputHasText ? (
              <button
                type="submit"
                className="inline-flex !h-[30px] !min-h-[30px] !w-[30px] !min-w-[30px] shrink-0 items-center justify-center rounded-full bg-(--fg) text-(--bg) transition-opacity hover:opacity-85"
                aria-label="Steer current task now"
                title="Steer current task now (Alt+Enter) · Enter queues it instead"
              >
                <ArrowUp className="h-4 w-4 stroke-[2.25]" />
              </button>
            ) : null}
            <button
              type="button"
              onClick={onAbortTurn}
              disabled={starting || stopping}
              className="inline-flex !h-[30px] !min-h-[30px] !w-[30px] !min-w-[30px] shrink-0 items-center justify-center rounded-full bg-(--fg) text-(--bg) transition-opacity hover:opacity-85 disabled:opacity-30"
              aria-label="Stop"
              title="Stop (Esc)"
            >
              <StopIcon className="h-2.5 w-2.5" />
            </button>
          </>
        ) : (
          <button
            type="submit"
            disabled={(!inputHasText && attachmentsCount === 0) || readingAttachments}
            className="inline-flex !h-[30px] !min-h-[30px] !w-[30px] !min-w-[30px] shrink-0 items-center justify-center rounded-full bg-(--fg) text-(--bg) transition-opacity hover:opacity-85 disabled:bg-(--hl3) disabled:opacity-100"
            aria-label="Send"
            title="Send (Enter)"
          >
            {starting ? <Spinner size="sm" /> : <ArrowUp className="h-4 w-4 stroke-[2.25]" />}
          </button>
        )}
      </div>
    </div>
  );
}
