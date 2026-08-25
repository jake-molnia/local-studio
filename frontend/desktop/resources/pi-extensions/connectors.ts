import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "./schema.ts";

type ToolResult = {
  content: Array<{ type: "text"; text: string }>;
  details: Record<string, unknown>;
};

interface InventoryTool {
  name: string;
  description?: string;
  inputSchema?: Record<string, unknown>;
}

interface InventoryConnector {
  id: string;
  name: string;
  tools: InventoryTool[];
}

const CALL_TIMEOUT_MS = 120_000;

const controllerBase = (): string =>
  process.env.LOCAL_STUDIO_MCP_BRIDGE_URL ?? "http://127.0.0.1:8082";

const modelId = (): string =>
  process.env.LOCAL_STUDIO_MCP_BRIDGE_MODEL ?? process.env.LOCAL_STUDIO_MODEL_ID ?? "";

const headers = (): Record<string, string> => {
  const key = process.env.LOCAL_STUDIO_MCP_BRIDGE_KEY;
  return key
    ? { "Content-Type": "application/json", Authorization: `Bearer ${key}` }
    : { "Content-Type": "application/json" };
};

const textResult = (text: string, details: Record<string, unknown>): ToolResult => ({
  content: [{ type: "text", text }],
  details,
});

const renderMcpResult = (result: unknown): string => {
  if (
    result &&
    typeof result === "object" &&
    Array.isArray((result as { content?: unknown[] }).content)
  ) {
    const blocks = (result as { content: Array<{ type?: string; text?: string }> }).content;
    const texts = blocks
      .map((block) => (block.type === "text" && block.text ? block.text : JSON.stringify(block)))
      .join("\n");
    return texts || "(empty result)";
  }
  return JSON.stringify(result ?? null);
};

async function callConnectorTool(
  connectorId: string,
  tool: string,
  args: Record<string, unknown>,
  signal: AbortSignal | undefined,
): Promise<ToolResult> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), CALL_TIMEOUT_MS);
  const abort = () => controller.abort();
  signal?.addEventListener("abort", abort, { once: true });
  if (signal?.aborted) controller.abort();
  try {
    const response = await fetch(`${controllerBase()}/internal/node/v1/connector-call`, {
      method: "POST",
      headers: headers(),
      body: JSON.stringify({ connector_id: connectorId, tool, args, model_id: modelId() }),
      signal: controller.signal,
    });
    const payload = (await response.json()) as { ok?: boolean; result?: unknown; error?: string };
    if (!response.ok || !payload.ok) {
      return textResult(`${connectorId}/${tool} failed: ${payload.error ?? response.status}`, {
        connectorId,
        tool,
        failed: true,
      });
    }
    return textResult(renderMcpResult(payload.result), { connectorId, tool });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return textResult(`${connectorId}/${tool} failed: ${message}`, {
      connectorId,
      tool,
      error: message,
      failed: true,
    });
  } finally {
    clearTimeout(timeout);
    signal?.removeEventListener("abort", abort);
  }
}

export default async function connectorsExtension(pi: ExtensionAPI): Promise<void> {
  let inventory: InventoryConnector[] = [];
  try {
    const url = `${controllerBase()}/internal/node/v1/connector-call?model_id=${encodeURIComponent(modelId())}`;
    const response = await fetch(url, { headers: headers(), signal: AbortSignal.timeout(30_000) });
    const payload = (await response.json()) as { connectors?: InventoryConnector[] };
    inventory = payload.connectors ?? [];
  } catch {
    return;
  }

  for (const connector of inventory) {
    for (const tool of connector.tools) {
      const qualifiedName = `${connector.id.replace(/-/g, "_")}_${tool.name.replace(/[^A-Za-z0-9_]/g, "_")}`;
      pi.registerTool({
        name: qualifiedName,
        label: `${connector.name}: ${tool.name}`,
        description: tool.description || `${tool.name} via the ${connector.name} connector`,
        parameters: Type.Unsafe<Record<string, unknown>>(
          tool.inputSchema ?? { type: "object", properties: {} },
        ),
        async execute(_id, params, signal) {
          return callConnectorTool(
            connector.id,
            tool.name,
            (params ?? {}) as Record<string, unknown>,
            signal,
          );
        },
      });
    }
  }
}
