import { useCallback, useState } from "react";
import { Schema } from "effect";
import { StatusPill } from "@/ui";
import {
  SettingsButton,
  SettingsFactRows,
  SettingsGroup,
  type SettingsFactRow,
} from "./settings-ui";
import { cleanSessionTitle } from "@/features/agent/messages/helpers";
import { SESSIONS_CHANGED_EVENT } from "@/lib/workspace-events";
import { useSidebarStatus } from "@/features/settings/use-sidebar-status";
import { useMountSubscription } from "@/hooks/use-mount-subscription";

const HarnessCatalogSchema = Schema.Struct({
  harnesses: Schema.Array(
    Schema.Struct({
      id: Schema.String,
      name: Schema.String,
      status: Schema.String,
      transport: Schema.String,
      nodeCount: Schema.optional(Schema.Number),
      installation: Schema.optional(
        Schema.Union([
          Schema.Null,
          Schema.Struct({
            source: Schema.String,
            executable: Schema.String,
            version: Schema.Union([Schema.Null, Schema.String]),
          }),
        ]),
      ),
      capabilities: Schema.Array(Schema.String),
    }),
  ),
});

type HarnessCatalog = Schema.Schema.Type<typeof HarnessCatalogSchema>;

export function ArchivedChatsSettings() {
  type Session = {
    id: string;
    projectName?: string;
    projectPath?: string;
    firstUserMessage?: string | null;
    updatedAt?: string;
    archived?: boolean;
    archivedAt?: string | null;
  };
  const [sessions, setSessions] = useState<Session[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [restoringId, setRestoringId] = useState<string | null>(null);
  const loadArchivedSessions = useCallback(async () => {
    setLoading(true);
    setError("");
    try {
      const response = await fetch("/api/agent/sessions/all?archived=1", {
        cache: "no-store",
      });
      const payload = (await response.json()) as { sessions?: Session[]; error?: string };
      if (!response.ok) throw new Error(payload.error || "Failed to load archived chats");
      setSessions(payload.sessions ?? []);
    } catch (loadError) {
      setSessions([]);
      setError(loadError instanceof Error ? loadError.message : "Failed to load archived chats");
    } finally {
      setLoading(false);
    }
  }, []);

  useMountSubscription(() => {
    void loadArchivedSessions();
    window.addEventListener(SESSIONS_CHANGED_EVENT, loadArchivedSessions);
    return () => window.removeEventListener(SESSIONS_CHANGED_EVENT, loadArchivedSessions);
  }, [loadArchivedSessions]);
  const unarchive = async (session: Session) => {
    setRestoringId(session.id);
    setError("");
    try {
      const response = await fetch(`/api/agent/sessions/${encodeURIComponent(session.id)}`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          archived: false,
          ...(session.projectPath ? { cwd: session.projectPath } : {}),
        }),
      });
      const payload = (await response.json()) as { error?: string };
      if (!response.ok) throw new Error(payload.error || "Failed to restore chat");
      setSessions((current) => current.filter((row) => row.id !== session.id));
      window.dispatchEvent(new Event(SESSIONS_CHANGED_EVENT));
    } catch (restoreError) {
      setError(restoreError instanceof Error ? restoreError.message : "Failed to restore chat");
    } finally {
      setRestoringId(null);
    }
  };
  const archiveRows: SettingsFactRow[] = error
    ? [
        {
          key: "archive-error",
          label: "Archive",
          description: error,
          value: "Try refreshing this settings section.",
          dim: true,
          status: { label: "error", tone: "warning" },
        },
      ]
    : sessions.length === 0
      ? [
          {
            key: "archive-empty",
            label: "Archive",
            description: "Use a session row menu to archive instead of deleting from disk.",
            value: loading ? "Loading archived chats…" : "No archived chats.",
            dim: true,
            status: { label: loading ? "loading" : "empty" },
          },
        ]
      : sessions.map((session) => ({
          key: session.id,
          label: cleanSessionTitle(session.firstUserMessage) || session.id,
          description: session.projectPath || "Session project metadata is not available.",
          value: session.id,
          mono: true,
          status: { label: "archived", tone: "info" },
          actions: (
            <SettingsButton
              onClick={() => void unarchive(session)}
              disabled={restoringId === session.id}
            >
              {restoringId === session.id ? "Restoring" : "Restore"}
            </SettingsButton>
          ),
          children: (
            <div className="text-[length:var(--fs-md)] text-(--dim)/55">
              {session.projectName ? `${session.projectName} · ` : ""}
              {session.archivedAt ? `archived ${session.archivedAt}` : session.updatedAt}
            </div>
          ),
        }));
  return (
    <SettingsGroup
      title="Archived chats"
      description="Archived sessions are excluded from normal chat fetches. Restore one here to return it to the sidebar."
      actions={<StatusPill>{loading ? "loading" : `${sessions.length} archived`}</StatusPill>}
    >
      <SettingsFactRows rows={archiveRows} />
    </SettingsGroup>
  );
}
export function SetupChecksSettings() {
  type Check = {
    id: string;
    label: string;
    ok: boolean;
    value: string;
    guidance: string;
    blocking?: boolean;
  };
  const [checks, setChecks] = useState<Check[]>([]);
  const [harnesses, setHarnesses] = useState<HarnessCatalog["harnesses"]>([]);
  const controllerStatus = useSidebarStatus();

  useMountSubscription(() => {
    void fetch("/api/agent/setup-checks", { cache: "no-store" })
      .then((res) => res.json() as Promise<{ checks?: Check[] }>)
      .then((payload) => setChecks(payload.checks ?? []))
      .catch(() => setChecks([]));
    void fetch("/api/agent/harnesses", { cache: "no-store" })
      .then((res) => res.json() as Promise<unknown>)
      .then((payload) =>
        setHarnesses([...Schema.decodeUnknownSync(HarnessCatalogSchema)(payload).harnesses]),
      )
      .catch(() => setHarnesses([]));
  }, []);
  const controllerCheck: Check = {
    id: "controller",
    label: "Controller connection",
    ok: controllerStatus.online,
    value: controllerStatus.online ? controllerStatus.activityLine : "offline",
    guidance: "Set a reachable controller URL in Settings → Connection before using Agents.",
  };
  const harnessChecks: Check[] = harnesses.map((harness) => ({
    id: `harness-${harness.id}`,
    label: `${harness.name} harness`,
    ok: harness.status === "available",
    value:
      harness.installation?.version ??
      (harness.nodeCount !== undefined ? `${harness.nodeCount} nodes` : harness.status),
    guidance: harness.installation
      ? `${harness.transport} via ${harness.installation.source}: ${harness.installation.executable}`
      : `${harness.transport}; install or enroll a node that offers this harness.`,
    blocking: false,
  }));
  const rows = [...checks, ...harnessChecks, controllerCheck];
  const blockers = rows.filter((check) => !check.ok && check.blocking !== false);
  const setupRows: SettingsFactRow[] = rows.map((check) => ({
    key: check.id,
    label: check.label,
    description: check.guidance,
    value: check.value,
    mono: true,
    status: { label: check.ok ? "ok" : "missing", tone: check.ok ? "good" : "warning" },
  }));
  return (
    <SettingsGroup
      title="First-time setup"
      description="Preflight checks prevent new users from landing in an empty Agent tab without explanation."
      actions={
        <StatusPill tone={blockers.length ? "warning" : "good"}>
          {blockers.length ? `${blockers.length} blockers` : "ready"}
        </StatusPill>
      }
    >
      <SettingsFactRows rows={setupRows} />
    </SettingsGroup>
  );
}
