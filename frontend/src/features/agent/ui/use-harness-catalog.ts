"use client";

import { Effect, Schema } from "effect";
import { useState } from "react";
import { HarnessCatalogSchema, type HarnessCatalogEntry } from "@shared/agent/harness-catalog";
import { useMountSubscription } from "@/hooks/use-mount-subscription";

export function useHarnessCatalog(): readonly HarnessCatalogEntry[] {
  const [harnesses, setHarnesses] = useState<readonly HarnessCatalogEntry[]>([]);
  useMountSubscription(() => {
    const controller = new AbortController();
    void Effect.runPromise(
      Effect.tryPromise({
        try: () => fetch("/api/agent/harnesses", { cache: "no-store", signal: controller.signal }),
        catch: (cause) => cause,
      }).pipe(
        Effect.flatMap((response) =>
          Effect.tryPromise({ try: () => response.json(), catch: (cause) => cause }),
        ),
        Effect.map(Schema.decodeUnknownSync(HarnessCatalogSchema)),
        Effect.catch(() => Effect.succeed({ harnesses: [] })),
      ),
    ).then((catalog) => setHarnesses(catalog.harnesses));
    return () => controller.abort();
  }, []);
  return harnesses;
}
