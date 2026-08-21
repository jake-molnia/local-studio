import { createRigsApi } from "./rigs";
import { createApiCore } from "./core";
import { createLogsApi } from "./logs";
import { createRecipesApi } from "./recipes";
import { createStudioApi } from "./studio";
import { createSystemApi } from "./system";
import type {
  SessionMetadata,
  SessionMetadataPayload,
  WorkersPayload,
} from "@local-studio/contracts/federation";

export function createApiClient(params: {
  baseUrl: string;
  useProxy: boolean;
  backendUrlOverride?: string;
  apiKeyOverride?: string;
}) {
  const core = createApiCore(params);
  return {
    ...createSystemApi(core),
    ...createRecipesApi(core),
    ...createLogsApi(core),
    ...createStudioApi(core),
    ...createRigsApi(core),
    getWorkers: (): Promise<WorkersPayload> => core.request("/studio/workers", { retries: 0 }),
    getSessionMetadata: (): Promise<SessionMetadataPayload> =>
      core.request("/studio/sessions", { retries: 0 }),
    upsertSessionMetadata: (metadata: SessionMetadata): Promise<{ success: boolean }> =>
      core.request(`/studio/sessions/${encodeURIComponent(metadata.session_id)}`, {
        method: "PUT",
        retries: 0,
        body: JSON.stringify(metadata),
      }),
    healthPoll: (timeoutMs?: number) => core.healthPoll(timeoutMs),
  };
}
