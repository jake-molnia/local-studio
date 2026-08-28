import { safeJson } from "@/features/agent/safe-json";
import { Effect, Schema } from "effect";
import type { GitAction, GitBranch, GitState } from "@/features/agent/contracts";
import type { GitSummary, Project, RepositoryOption } from "@/features/agent/projects/types";

const RepositoryOptionSchema = Schema.Struct({
  accountId: Schema.String,
  accountLabel: Schema.String,
  organization: Schema.String,
  name: Schema.String,
  repository: Schema.String,
  url: Schema.String,
  defaultBranch: Schema.String,
});

const RepositoriesPayloadSchema = Schema.Struct({
  repositories: Schema.Array(RepositoryOptionSchema),
  accounts: Schema.Number,
  defaultAccountId: Schema.optional(Schema.String),
});

const PreparedWorkspaceSchema = Schema.Struct({
  path: Schema.String,
  ref: Schema.String,
  detached: Schema.Boolean,
});

const ProjectRefsSchema = Schema.Struct({ refs: Schema.Array(Schema.String) });

const ProjectSchema = Schema.Struct({
  id: Schema.String,
  name: Schema.String,
  path: Schema.String,
  addedAt: Schema.String,
  exists: Schema.Boolean,
  hasGit: Schema.Boolean,
  branch: Schema.NullOr(Schema.String),
  accountId: Schema.optional(Schema.String),
  organization: Schema.optional(Schema.String),
  repository: Schema.optional(Schema.String),
  repositoryUrl: Schema.optional(Schema.String),
  defaultBranch: Schema.String,
});

const ProjectImportProgressSchema = Schema.Struct({
  stage: Schema.Literals(["preparing", "creating", "uploading", "saving"]),
  message: Schema.String,
  progress: Schema.NullOr(Schema.Number),
});

const ProjectEnvelopeSchema = Schema.Struct({ project: ProjectSchema });
const ProjectImportFailureSchema = Schema.Struct({
  error: Schema.String,
  detail: Schema.optional(Schema.String),
});

type DesktopBridge = {
  openDirectory?: () => Promise<string | null>;
};

function getDesktopBridge(): DesktopBridge | null {
  if (typeof window === "undefined") return null;
  const candidate = (window as unknown as { localStudioDesktop?: Partial<DesktopBridge> })
    .localStudioDesktop;
  if (!candidate) return null;
  const hasBridgeMethod = typeof candidate.openDirectory === "function";
  return hasBridgeMethod ? (candidate as DesktopBridge) : null;
}

export type OpenProjectDirectoryResult =
  | { source: "desktop"; project: Project | null }
  | { source: "fallback" };

export type ProjectImportProgress = Schema.Schema.Type<typeof ProjectImportProgressSchema>;
export type ProjectImportProgressHandler = (progress: ProjectImportProgress) => void;

export async function openProjectDirectory(
  accountId: string,
  onProgress?: ProjectImportProgressHandler,
): Promise<OpenProjectDirectoryResult> {
  const bridge = getDesktopBridge();
  if (!bridge?.openDirectory) return { source: "fallback" };
  const path = await bridge.openDirectory();
  return {
    source: "desktop",
    project: path ? await addProjectFromPath(path, accountId, onProgress) : null,
  };
}

export async function addProjectFromPath(
  path: string,
  accountId: string,
  onProgress?: ProjectImportProgressHandler,
): Promise<Project> {
  const folder = path
    .replace(/[\\/]+$/u, "")
    .split(/[\\/]/u)
    .at(-1)
    ?.trim();
  const repository = folder?.replace(/[^A-Za-z0-9._-]+/gu, "-").replace(/^-+|-+$/gu, "");
  if (!repository || repository === "." || repository === "..")
    throw new Error("Choose a project folder");
  onProgress?.({ stage: "preparing", message: "Starting repository sync", progress: 1 });
  const response = await fetch("/api/agent/projects/import", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ import: true, path, accountId, repository }),
  });
  if (!response.ok) {
    const payload = (await response.json().catch(() => ({}))) as {
      error?: string;
      detail?: string;
    };
    throw new Error(payload.detail || payload.error || "Failed to add project");
  }
  return Effect.runPromise(readProjectImportStream(response, onProgress));
}

function readProjectImportStream(
  response: Response,
  onProgress?: ProjectImportProgressHandler,
): Effect.Effect<Project, Error> {
  return Effect.tryPromise({
    try: async () => {
      const reader = response.body?.getReader();
      if (!reader) throw new Error("Repository sync did not return a progress stream");
      const decoder = new TextDecoder();
      let pending = "";
      let project: Project | null = null;
      while (true) {
        const result = await reader.read();
        pending += decoder.decode(result.value, { stream: !result.done }).replaceAll("\r\n", "\n");
        const frames = pending.split("\n\n");
        pending = frames.pop() ?? "";
        for (const frame of frames) {
          const lines = frame.split("\n");
          const event = lines
            .find((line) => line.startsWith("event:"))
            ?.slice(6)
            .trim();
          const data = lines
            .filter((line) => line.startsWith("data:"))
            .map((line) => line.slice(5).trimStart())
            .join("\n");
          if (!event || !data) continue;
          const value = JSON.parse(data) as unknown;
          if (event === "progress") {
            onProgress?.(Schema.decodeUnknownSync(ProjectImportProgressSchema)(value));
          } else if (event === "complete") {
            project = Schema.decodeUnknownSync(ProjectEnvelopeSchema)(value).project;
          } else if (event === "error") {
            const failure = Schema.decodeUnknownSync(ProjectImportFailureSchema)(value);
            throw new Error(failure.detail || failure.error);
          }
        }
        if (result.done) break;
      }
      if (!project) throw new Error("Repository sync ended before the project was saved");
      return project;
    },
    catch: (cause) => (cause instanceof Error ? cause : new Error("Repository sync failed")),
  });
}

export async function listRepositoryOptions(): Promise<{
  repositories: readonly RepositoryOption[];
  accounts: number;
  defaultAccountId?: string;
}> {
  const response = await fetch("/api/agent/projects/repositories", { cache: "no-store" });
  const payload = (await response.json()) as unknown;
  if (!response.ok) {
    const failure = payload as { error?: string };
    throw new Error(failure.error || "Failed to load repositories");
  }
  return Schema.decodeUnknownSync(RepositoriesPayloadSchema)(payload);
}

export async function createRepositoryProject(
  accountId: string,
  repository: string,
): Promise<Project> {
  const response = await fetch("/api/agent/projects", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ create: true, accountId, repository }),
  });
  const payload = (await response.json()) as { project?: Project; error?: string };
  if (!response.ok || !payload.project)
    throw new Error(payload.error || "Failed to create project");
  return payload.project;
}

export async function addRepositoryProject(repository: RepositoryOption): Promise<Project> {
  const response = await fetch("/api/agent/projects", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      accountId: repository.accountId,
      repository: repository.repository,
      repositoryUrl: repository.url,
      defaultBranch: repository.defaultBranch,
    }),
  });
  const payload = (await response.json()) as { project?: Project; error?: string };
  if (!response.ok || !payload.project) throw new Error(payload.error || "Failed to add project");
  return payload.project;
}

export async function prepareTaskWorkspace(input: {
  projectId: string;
  sessionId: string;
  ref?: string;
  branch?: string;
}): Promise<{ path: string; ref: string; detached: boolean }> {
  const response = await fetch("/api/agent/projects/workspace", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(input),
  });
  const payload = await safeJson<unknown>(response);
  if (!response.ok) {
    const failure = payload as { error?: string; detail?: string };
    throw new Error(failure.error || failure.detail || "Failed to prepare task workspace");
  }
  return Schema.decodeUnknownSync(PreparedWorkspaceSchema)(payload);
}

export async function listProjectRefs(projectId: string): Promise<readonly string[]> {
  const response = await fetch(
    `/api/agent/projects/refs?projectId=${encodeURIComponent(projectId)}`,
    { cache: "no-store" },
  );
  const payload = await response.json();
  if (!response.ok) throw new Error("Failed to load branches");
  return Schema.decodeUnknownSync(ProjectRefsSchema)(payload).refs;
}

export async function removeProject(id: string): Promise<void> {
  const response = await fetch(`/api/agent/projects?id=${encodeURIComponent(id)}`, {
    method: "DELETE",
  });
  if (!response.ok) {
    const payload = (await response.json().catch(() => ({}))) as { error?: string };
    throw new Error(payload.error || "Failed to remove project");
  }
}

export async function loadGitSummary(cwd: string): Promise<GitSummary | null> {
  const response = await fetch(`/api/agent/git?cwd=${encodeURIComponent(cwd)}`, {
    cache: "no-store",
  });
  const payload = await safeJson<GitState>(response);
  return {
    isRepo: payload.isRepo === true,
    branch: payload.branch ?? null,
    additions: payload.additions ?? 0,
    deletions: payload.deletions ?? 0,
    statusCount: payload.status?.length ?? 0,
  };
}

export async function initGit(cwd: string): Promise<void> {
  const response = await fetch(`/api/agent/git?cwd=${encodeURIComponent(cwd)}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "init" }),
  });
  if (!response.ok) {
    const payload = await safeJson<{ error?: string }>(response);
    throw new Error(payload.error || "Failed to initialize git repository");
  }
}

export async function listBranches(cwd: string): Promise<GitBranch[]> {
  const response = await fetch(`/api/agent/git/branches?cwd=${encodeURIComponent(cwd)}`, {
    cache: "no-store",
  });
  const payload = await safeJson<{ branches?: GitBranch[]; error?: string }>(response);
  if (!response.ok) throw new Error(payload.error || "Failed to list branches");
  return payload.branches ?? [];
}

export async function runGitAction(cwd: string, action: GitAction): Promise<void> {
  const response = await fetch(`/api/agent/git?cwd=${encodeURIComponent(cwd)}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(action),
  });
  if (!response.ok) {
    const payload = await safeJson<{ error?: string }>(response);
    throw new Error(payload.error || "Git operation failed");
  }
}

export async function switchBranch(cwd: string, branch: string): Promise<void> {
  await runGitAction(cwd, { action: "switch_branch", branch });
}

export async function createBranch(cwd: string, branch: string): Promise<void> {
  await runGitAction(cwd, { action: "create_branch", branch });
}
