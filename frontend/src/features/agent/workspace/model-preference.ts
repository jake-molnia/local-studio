export const DEFAULT_AGENT_MODEL_KEY = "local-studio.agent.defaultModel";
export const DEFAULT_AGENT_ROUTE_KEY = "local-studio.agent.defaultRoute";

export function readDefaultAgentModel(storage: Pick<Storage, "getItem">): string {
  return storage.getItem(DEFAULT_AGENT_MODEL_KEY)?.trim() ?? "";
}

export function readDefaultAgentRoute(storage: Pick<Storage, "getItem">): string {
  return storage.getItem(DEFAULT_AGENT_ROUTE_KEY)?.trim() ?? "";
}

export function writeDefaultAgentModel(
  storage: Pick<Storage, "setItem">,
  modelId: string,
  routeId: string,
): void {
  storage.setItem(DEFAULT_AGENT_MODEL_KEY, modelId);
  storage.setItem(DEFAULT_AGENT_ROUTE_KEY, routeId);
}
