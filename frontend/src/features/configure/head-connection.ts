import { Effect } from "effect";
import { createApiClient } from "@/lib/api/create-api-client";
import {
  loadSavedControllers,
  normalizeControllerUrl,
  saveSavedControllers,
} from "@/lib/api/controllers";
import { setHeadConnection } from "@/lib/api/head-controller";
import { scheduleDurableUiPreferencesSave } from "@/lib/desktop-ui-preferences";

const HEAD_PROBE_REQUEST = { timeout: 10_000, retries: 0 } as const;

function headProbeError(cause: unknown): Error {
  const status = cause instanceof Error ? (cause as Error & { status?: number }).status : undefined;
  if (status === 404) {
    return new Error("That controller is reachable, but it is not running in Head mode");
  }
  return new Error(
    cause instanceof Error
      ? `Could not connect to the Head: ${cause.message}`
      : "Could not connect to the Head",
  );
}

function requireHeadUrl(value: string): string {
  const normalized = normalizeControllerUrl(value);
  try {
    const parsed = new URL(normalized);
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") throw new Error();
    return normalized;
  } catch {
    throw new Error("Enter the full Head controller URL, for example http://192.168.1.90:8080");
  }
}

const connectHeadEffect = (input: { name: string; url: string; apiKey?: string }) =>
  Effect.gen(function* () {
    const url = requireHeadUrl(input.url);
    const apiKey = input.apiKey?.trim() ?? "";
    const probe = createApiClient({
      baseUrl: "/api/proxy",
      useProxy: true,
      backendUrlOverride: url,
      apiKeyOverride: apiKey,
    });

    const workerPayload = yield* Effect.tryPromise({
      try: () => probe.getWorkers(HEAD_PROBE_REQUEST),
      catch: headProbeError,
    });

    if (workerPayload.mode !== "head") {
      return yield* Effect.fail(new Error("That controller is not running in Head mode"));
    }

    const controllers = loadSavedControllers().filter(
      (controller) => normalizeControllerUrl(controller.url) !== url,
    );
    const name = input.name.trim() || "Studio Head";
    saveSavedControllers([...controllers, { url, name, ...(apiKey ? { apiKey } : {}) }]);
    const persisted = yield* Effect.tryPromise({
      try: () =>
        fetch("/api/proxy/api/agent/head-connection", {
          method: "PUT",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ name, url, apiKey }),
        }),
      catch: () => new Error("Could not persist the Head connection on this desktop"),
    });
    if (!persisted.ok) {
      return yield* Effect.fail(
        new Error("The Head is reachable, but this desktop could not save the connection"),
      );
    }
    setHeadConnection({ name, url });
    scheduleDurableUiPreferencesSave();
    return url;
  });

export const connectHead = (input: {
  name: string;
  url: string;
  apiKey?: string;
}): Promise<string> => Effect.runPromise(connectHeadEffect(input));
