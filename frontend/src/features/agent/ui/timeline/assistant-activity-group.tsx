import { memo, useMemo } from "react";
import type { ThinkingBlock, ToolBlock } from "@/features/agent/messages";
import { useReasoningVisible } from "@/features/agent/messages/use-reasoning-visible";
import {
  mergeReasoningBlocks,
  type ActivitySegment,
} from "@/features/agent/ui/timeline/activity-grouping";
import { ToolBlockView } from "@/features/agent/ui/timeline/tool-block-view";
import { Brain } from "@/ui/icon-registry";

type ActivityItem =
  | { kind: "tool"; id: string; block: ToolBlock }
  | { kind: "reasoning"; id: string; block: ThinkingBlock };

function cleanThinkingText(text: string): string {
  return text.replace(/\*\*([\s\S]*?)\*\*/g, "$1").trim();
}

function ReasoningRow({ block, live }: { block: ThinkingBlock; live: boolean }) {
  return (
    <div className="flex min-w-0 items-start gap-2 px-1 py-1">
      <Brain
        className="mt-0.5 h-3.5 w-3.5 shrink-0 text-(--color-command-node-foreground)/75"
        strokeWidth={1.7}
      />
      <div
        className={`min-w-0 flex-1 whitespace-pre-wrap text-[length:var(--fs-sm)] leading-[1.55] text-(--fg)/68 ${live ? "codex-shimmer-text" : ""}`}
      >
        {cleanThinkingText(block.text)}
      </div>
    </div>
  );
}

type AssistantActivityGroupProps = {
  segments: ActivitySegment[];
  live: boolean;
};

function sameSegments(previous: ActivitySegment[], next: ActivitySegment[]): boolean {
  return (
    previous.length === next.length &&
    previous.every(
      (segment, segmentIndex) =>
        segment.kind === next[segmentIndex]?.kind &&
        segment.blocks.length === next[segmentIndex]?.blocks.length &&
        segment.blocks.every(
          (block, blockIndex) => block === next[segmentIndex]?.blocks[blockIndex],
        ),
    )
  );
}

export const AssistantActivityGroup = memo(
  function AssistantActivityGroup({ segments, live }: AssistantActivityGroupProps) {
    const showReasoning = useReasoningVisible();
    const items = useMemo<ActivityItem[]>(() => {
      const next: ActivityItem[] = [];
      for (const segment of segments) {
        if (segment.kind === "tools") {
          next.push(
            ...segment.blocks.map((block) => ({ kind: "tool" as const, id: block.id, block })),
          );
          continue;
        }
        if (!showReasoning) continue;
        const block = mergeReasoningBlocks(segment.blocks);
        if (block) next.push({ kind: "reasoning", id: block.id, block });
      }
      return next;
    }, [segments, showReasoning]);

    const lastReasoningIndex = items.findLastIndex((item) => item.kind === "reasoning");
    if (items.length === 0) return null;

    return (
      <div className="flex min-w-0 flex-col gap-0.5">
        {items.map((item, index) =>
          item.kind === "reasoning" ? (
            <ReasoningRow
              key={item.id}
              block={item.block}
              live={live && index === lastReasoningIndex}
            />
          ) : (
            <ToolBlockView key={item.id} block={item.block} />
          ),
        )}
      </div>
    );
  },
  (previous, next) => previous.live === next.live && sameSegments(previous.segments, next.segments),
);
