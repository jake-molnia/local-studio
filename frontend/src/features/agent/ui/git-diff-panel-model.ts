import { parsePatchFiles, type CodeViewDiffItem } from "@pierre/diffs";
import type { GitState } from "@/features/agent/contracts";

export type GitDiffPayload = Partial<GitState>;
export type DiffViewMode = "unified" | "split";

function patchCacheKey(diff: string) {
  let hash = 0x811c9dc5;
  for (let index = 0; index < diff.length; index += 1) {
    hash ^= diff.charCodeAt(index);
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return `working-tree:${diff.length}:${hash.toString(36)}`;
}

export function parseUnifiedDiff(diff: string): CodeViewDiffItem[] {
  const normalized = diff.trim();
  if (!normalized) return [];
  try {
    return parsePatchFiles(normalized, patchCacheKey(normalized)).flatMap((patch) =>
      patch.files.map((fileDiff, index) => ({
        id: fileDiff.cacheKey ?? `${fileDiff.prevName ?? "file"}:${fileDiff.name}:${index}`,
        type: "diff" as const,
        fileDiff,
      })),
    );
  } catch {
    return [];
  }
}

export function gitDiffHeaderTitle(payload: GitDiffPayload | null, cwd: string | null): string {
  if (payload?.branch) return payload.branch;
  return cwd ? "Working tree diff" : "No directory";
}
