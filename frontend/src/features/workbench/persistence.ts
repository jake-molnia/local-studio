import { Schema } from "effect";
import type { ComputerTab } from "@/features/agent/tools/types";
import type { WorkbenchState, WorkbenchTab } from "@/features/workbench/model";

const WORKBENCH_STORAGE_KEY = "local-studio.workbench.tabs.v5";
const MAX_TABS = 80;
const MAX_CLOSED_TABS = 200;

const WorkbenchTabSchema = Schema.Struct({
  id: Schema.String,
  kind: Schema.Union([Schema.Literal("task"), Schema.Literal("tool")]),
  title: Schema.String,
  resourceId: Schema.String,
  groupId: Schema.String,
  groupTitle: Schema.String,
  href: Schema.optional(Schema.String),
  projectId: Schema.optional(Schema.String),
  sessionId: Schema.optional(Schema.String),
  threadId: Schema.optional(Schema.String),
  tool: Schema.optional(Schema.String),
  status: Schema.optional(Schema.String),
});

const WorkbenchStoreSchema = Schema.Struct({
  version: Schema.Literal(5),
  tabs: Schema.Array(WorkbenchTabSchema),
  activeId: Schema.NullOr(Schema.String),
  closedTabIds: Schema.Array(Schema.String),
});

const decodeWorkbenchStore = Schema.decodeUnknownOption(WorkbenchStoreSchema);
const COMPUTER_TABS = new Set<ComputerTab>(["side-chat", "browser", "files", "diff", "terminal"]);

function normalizeTab(value: typeof WorkbenchTabSchema.Type): WorkbenchTab | null {
  const id = value.id.trim();
  const resourceId = value.resourceId.trim();
  const groupId = value.groupId.trim();
  const title = value.title.trim().slice(0, 160);
  const groupTitle = value.groupTitle.trim().slice(0, 160);
  if (!id || !resourceId || !groupId || !title || !groupTitle) return null;
  if (value.kind === "tool" && !COMPUTER_TABS.has(value.tool as ComputerTab)) return null;
  return {
    id,
    kind: value.kind,
    title,
    resourceId,
    groupId,
    groupTitle,
    ...(value.href ? { href: value.href } : {}),
    ...(value.projectId ? { projectId: value.projectId } : {}),
    ...(value.sessionId ? { sessionId: value.sessionId } : {}),
    ...(value.threadId ? { threadId: value.threadId } : {}),
    ...(value.kind === "tool" ? { tool: value.tool as ComputerTab } : {}),
    ...(value.status ? { status: value.status } : {}),
  };
}

export function loadWorkbenchState(fallback: WorkbenchState): WorkbenchState {
  if (typeof window === "undefined") return fallback;
  try {
    const decoded = decodeWorkbenchStore(
      JSON.parse(window.localStorage.getItem(WORKBENCH_STORAGE_KEY) ?? "null"),
    );
    if (decoded._tag === "None") return fallback;
    const tabs: WorkbenchTab[] = [];
    const ids = new Set<string>();
    for (const candidate of decoded.value.tabs) {
      const tab = normalizeTab(candidate);
      if (!tab || ids.has(tab.id)) continue;
      ids.add(tab.id);
      tabs.push(tab);
      if (tabs.length >= MAX_TABS) break;
    }
    if (tabs.length === 0) return fallback;
    const activeId = decoded.value.activeId;
    return {
      tabs,
      activeId: activeId && ids.has(activeId) ? activeId : (tabs.at(-1)?.id ?? null),
      closedTabIds: [...new Set(decoded.value.closedTabIds)].slice(-MAX_CLOSED_TABS),
    };
  } catch {
    return fallback;
  }
}

export function writeWorkbenchState(state: WorkbenchState): void {
  if (typeof window === "undefined") return;
  try {
    window.localStorage.setItem(
      WORKBENCH_STORAGE_KEY,
      JSON.stringify({
        version: 5,
        tabs: state.tabs.slice(-MAX_TABS),
        activeId: state.activeId,
        closedTabIds: state.closedTabIds.slice(-MAX_CLOSED_TABS),
      }),
    );
  } catch {}
}
