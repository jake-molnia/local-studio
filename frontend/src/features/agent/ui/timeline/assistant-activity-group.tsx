import { memo, useMemo } from "react";
import type { ThinkingBlock, ToolBlock } from "@/features/agent/messages";
import { useReasoningVisible } from "@/features/agent/messages/use-reasoning-visible";
import {
  mergeReasoningBlocks,
  type ActivitySegment,
} from "@/features/agent/ui/timeline/activity-grouping";
import { ToolBlockView } from "@/features/agent/ui/timeline/tool-block-view";

export const AssistantActivityGroup = memo(function AssistantActivityGroup({
  segments,
  live,
}: {
  segments: ActivitySegment[];
  live: boolean;
}) {
  const showReasoning = useReasoningVisible();
  const items = useMemo<
    Array<
      | { kind: "tool"; id: string; block: ToolBlock }
      | { kind: "reasoning"; id: string; block: ThinkingBlock }
    >
  >(() => {
    const next: Array<
      | { kind: "tool"; id: string; block: ToolBlock }
      | { kind: "reasoning"; id: string; block: ThinkingBlock }
    > = [];
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

  if (items.length === 0) return null;

  return (
    <div className="flex min-w-0 flex-col gap-2.5">
      {items.map((item, index) =>
        item.kind === "reasoning" ? (
          <div
            key={item.id}
            className={`whitespace-pre-wrap border-l border-(--separator) pl-3 text-[length:var(--fs-base)] leading-[1.625] text-(--fg)/62 ${
              live && index === items.length - 1 ? "codex-shimmer-text" : ""
            }`}
          >
            {item.block.text}
          </div>
        ) : (
          <ToolBlockView key={item.id} block={item.block} />
        ),
      )}
    </div>
  );
});
