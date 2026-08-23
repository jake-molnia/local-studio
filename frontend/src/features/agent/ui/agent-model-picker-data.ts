import type { AgentModel } from "@/features/agent/workspace/types";

export type ModelCompany = {
  key: string;
  label: string;
  logo?: string;
};

export type ModelRoute = {
  key: string;
  label: string;
  model: AgentModel;
};

export type ModelChoice = {
  key: string;
  label: string;
  company: ModelCompany;
  routes: ModelRoute[];
};

const COMPANIES: ModelCompany[] = [
  { key: "openai", label: "OpenAI", logo: "/model-logos/openai.webp" },
  { key: "anthropic", label: "Anthropic" },
  { key: "google", label: "Google", logo: "/model-logos/google.webp" },
  { key: "xai", label: "xAI" },
  { key: "meta", label: "Meta", logo: "/model-logos/meta-llama.webp" },
  { key: "deepseek", label: "DeepSeek", logo: "/model-logos/deepseek-ai.webp" },
  { key: "qwen", label: "Qwen", logo: "/model-logos/Qwen.webp" },
  { key: "mistral", label: "Mistral", logo: "/model-logos/mistralai.webp" },
  { key: "minimax", label: "MiniMax", logo: "/model-logos/MiniMaxAI.webp" },
  { key: "moonshot", label: "Moonshot", logo: "/model-logos/moonshotai.webp" },
  { key: "zai", label: "Z.ai", logo: "/model-logos/zai-org.webp" },
  { key: "nvidia", label: "NVIDIA", logo: "/model-logos/nvidia.webp" },
  { key: "microsoft", label: "Microsoft", logo: "/model-logos/microsoft.webp" },
  { key: "cohere", label: "Cohere" },
  { key: "local", label: "Local" },
];

const COMPANY_BY_KEY = new Map(COMPANIES.map((company) => [company.key, company]));
const COMPANY_RULES: Array<{ key: string; matches: (value: string) => boolean }> = [
  { key: "anthropic", matches: (value) => value.includes("claude") },
  {
    key: "google",
    matches: (value) => value.includes("gemini") || value.includes("gemma"),
  },
  { key: "xai", matches: (value) => value.includes("grok") },
  { key: "meta", matches: (value) => value.includes("llama") },
  { key: "deepseek", matches: (value) => value.includes("deepseek") },
  { key: "qwen", matches: (value) => value.includes("qwen") },
  {
    key: "mistral",
    matches: (value) =>
      value.includes("mistral") || value.includes("codestral") || value.includes("ministral"),
  },
  { key: "minimax", matches: (value) => value.includes("minimax") },
  {
    key: "moonshot",
    matches: (value) => value.includes("kimi") || value.includes("moonshot"),
  },
  {
    key: "zai",
    matches: (value) => value.includes("glm") || value.includes("zai") || value.includes("z.ai"),
  },
  {
    key: "nvidia",
    matches: (value) => value.includes("nemotron") || value.includes("nvidia"),
  },
  { key: "microsoft", matches: (value) => value.includes("phi-") },
  {
    key: "cohere",
    matches: (value) => value.includes("command-r") || value.includes("cohere"),
  },
  {
    key: "openai",
    matches: (value) =>
      value.includes("gpt") ||
      value.includes("codex") ||
      /(^|[\s/_-])o[134](?:[\s/_-]|$)/.test(value),
  },
];
const ROUTE_PREFIXES = new Set([
  "cursor",
  "openai-codex",
  "codex",
  "openrouter",
  "anthropic",
  "google",
  "gemini",
  "xai",
  "openai",
  "groq",
  "together",
  "fireworks",
  "deepinfra",
  "ollama",
  "lmstudio",
]);

export function buildModelChoices(models: AgentModel[]): ModelChoice[] {
  const choices = new Map<string, ModelChoice>();
  for (const model of models) {
    const slug = canonicalModelSlug(model);
    const company = modelCompany(slug, model.name);
    const key = `${company.key}:${slug.toLocaleLowerCase()}`;
    const route = modelRoute(model);
    const existing = choices.get(key);
    if (existing) {
      if (!existing.routes.some((candidate) => candidate.model.id === model.id)) {
        existing.routes.push(route);
      }
      continue;
    }
    choices.set(key, {
      key,
      label: modelDisplayName(model, slug),
      company,
      routes: [route],
    });
  }
  return [...choices.values()]
    .map((choice) => ({
      ...choice,
      routes: choice.routes.toSorted(
        (left, right) =>
          Number(right.model.active) - Number(left.model.active) ||
          left.label.localeCompare(right.label),
      ),
    }))
    .toSorted((left, right) => left.label.localeCompare(right.label));
}

export function availableModelCompanies(choices: ModelChoice[]): ModelCompany[] {
  const available = new Set(choices.map((choice) => choice.company.key));
  return COMPANIES.filter((company) => available.has(company.key));
}

export function activeModelChoice(
  choices: ModelChoice[],
  selectedModel: string,
): ModelChoice | null {
  return (
    choices.find((choice) => choice.routes.some((route) => route.model.id === selectedModel)) ??
    null
  );
}

export function routeForChoice(
  choice: ModelChoice,
  selectedRoute: ModelRoute | null,
  defaultModel?: string,
): ModelRoute {
  const matchingProvider = selectedRoute
    ? choice.routes.find((route) => route.key === selectedRoute.key)
    : undefined;
  return (
    matchingProvider ??
    choice.routes.find((route) => route.model.id === defaultModel) ??
    choice.routes.find((route) => route.model.active) ??
    choice.routes[0]!
  );
}

export function modelChoiceSearchText(choice: ModelChoice): string {
  return [
    choice.label,
    choice.company.label,
    ...choice.routes.flatMap((route) => [
      route.label,
      route.model.id,
      route.model.rawId,
      route.model.name,
      route.model.controllerName,
    ]),
  ]
    .filter(Boolean)
    .join(" ")
    .toLocaleLowerCase();
}

export function selectedModelRoute(models: AgentModel[], selectedModel: string): ModelRoute | null {
  const model = models.find((candidate) => candidate.id === selectedModel);
  return model ? modelRoute(model) : null;
}

function canonicalModelSlug(model: AgentModel): string {
  const raw = (model.rawId || model.id).trim();
  const segments = raw.split("/").filter(Boolean);
  if (segments.length > 1 && ROUTE_PREFIXES.has(segments[0]!.toLocaleLowerCase())) {
    return segments.slice(1).join("/");
  }
  return raw;
}

function modelCompany(slug: string, name: string): ModelCompany {
  const value = `${slug} ${name}`.toLocaleLowerCase();
  const key = COMPANY_RULES.find((rule) => rule.matches(value))?.key ?? "local";
  return COMPANY_BY_KEY.get(key) ?? COMPANY_BY_KEY.get("local")!;
}

function modelDisplayName(model: AgentModel, slug: string): string {
  const baseName = model.name.split(" · ")[0]?.trim();
  if (
    baseName &&
    !baseName.includes("/") &&
    baseName.toLocaleLowerCase() !== model.id.toLocaleLowerCase()
  ) {
    return baseName;
  }
  return slug
    .split(/[\s_-]+/)
    .filter(Boolean)
    .map((part) => displayToken(part))
    .join(" ");
}

function displayToken(token: string): string {
  const lower = token.toLocaleLowerCase();
  if (lower === "gpt") return "GPT";
  if (lower === "xhigh") return "XHigh";
  if (/^o[134]$/.test(lower)) return lower.toLocaleUpperCase();
  if (/^\d+(?:\.\d+)*[a-z]?$/.test(lower)) return token;
  return `${token.charAt(0).toLocaleUpperCase()}${token.slice(1)}`;
}

function modelRoute(model: AgentModel): ModelRoute {
  const raw = (model.rawId || "").trim();
  const rawPrefix = raw.split("/")[0]?.toLocaleLowerCase();
  const explicitPrefix =
    raw.includes("/") && rawPrefix && ROUTE_PREFIXES.has(rawPrefix) ? rawPrefix : "";
  const key =
    explicitPrefix || model.providerId || model.controllerUrl || model.controllerName || "local";
  return { key, label: routeDisplayName(key, model.controllerName), model };
}

function routeDisplayName(route: string, controllerName?: string): string {
  const normalized = route.toLocaleLowerCase();
  if (normalized === "cursor") return "Cursor";
  if (normalized === "openai-codex" || normalized === "codex") return "Codex";
  if (normalized === "openrouter") return "OpenRouter";
  if (normalized === "lmstudio") return "LM Studio";
  if (route.startsWith("http")) return controllerName || "Local Studio";
  return route
    .split(/[-_]/)
    .filter(Boolean)
    .map((part) => `${part.charAt(0).toLocaleUpperCase()}${part.slice(1)}`)
    .join(" ");
}
