"use client";

import { useSyncExternalStore } from "react";
import { effectInterval, type EffectTimer } from "@/lib/effect-timers";

let minute = Math.floor(Date.now() / 60_000);
let timer: EffectTimer | null = null;
const listeners = new Set<() => void>();

function tick() {
  const next = Math.floor(Date.now() / 60_000);
  if (next === minute) return;
  minute = next;
  for (const listener of listeners) listener();
}

function subscribe(listener: () => void) {
  listeners.add(listener);
  timer ??= effectInterval(tick, 15_000);
  return () => {
    listeners.delete(listener);
    if (listeners.size !== 0) return;
    timer?.cancel();
    timer = null;
  };
}

export function useSidebarMinute() {
  return useSyncExternalStore(
    subscribe,
    () => minute,
    () => 0,
  );
}
