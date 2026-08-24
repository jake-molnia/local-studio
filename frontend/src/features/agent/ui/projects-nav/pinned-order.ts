export type PinnedOrderEntry = {
  id: string;
  identities: readonly string[];
};

const PINNED_SESSION_ORDER_KEY = "local-studio.agent.pinned-session-order.v1";

function entryPosition(entry: PinnedOrderEntry, positions: ReadonlyMap<string, number>): number {
  return [entry.id, ...entry.identities].reduce(
    (best, identity) => Math.min(best, positions.get(identity) ?? Number.MAX_SAFE_INTEGER),
    Number.MAX_SAFE_INTEGER,
  );
}

export function orderPinnedEntries<T extends PinnedOrderEntry>(
  entries: readonly T[],
  order: readonly string[],
): T[] {
  const positions = new Map(order.map((id, index) => [id, index] as const));
  return entries
    .map((entry, index) => ({ entry, index, position: entryPosition(entry, positions) }))
    .sort((left, right) => left.position - right.position || left.index - right.index)
    .map(({ entry }) => entry);
}

export function readPinnedSessionOrder(): string[] {
  if (typeof window === "undefined") return [];
  try {
    const parsed = JSON.parse(
      window.localStorage.getItem(PINNED_SESSION_ORDER_KEY) ?? "[]",
    ) as unknown;
    return Array.isArray(parsed)
      ? parsed.filter((entry): entry is string => typeof entry === "string")
      : [];
  } catch {
    return [];
  }
}

export function writePinnedSessionOrder(order: readonly string[]): void {
  if (typeof window === "undefined") return;
  try {
    window.localStorage.setItem(PINNED_SESSION_ORDER_KEY, JSON.stringify([...order]));
  } catch {}
}
