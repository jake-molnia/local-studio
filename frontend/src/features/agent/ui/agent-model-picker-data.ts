import type {
  CatalogAgentModel as AgentModel,
  ModelLab,
  ModelRouteOffer,
} from "@/features/agent/models";

export type ModelCompany = {
  key: string;
  label: string;
  logo?: string;
};

export type ModelRoute = {
  key: string;
  label: string;
  route: ModelRouteOffer;
  model: AgentModel;
};

export type ModelChoice = {
  key: string;
  label: string;
  company: ModelCompany;
  model: AgentModel;
  routes: ModelRoute[];
};

export function buildModelChoices(models: AgentModel[]): ModelChoice[] {
  return models
    .map((model) => ({
      key: model.id,
      label: model.name,
      company: companyFromLab(model.lab),
      model,
      routes: model.routes.map((route) => ({
        key: route.id,
        label: route.label,
        route,
        model,
      })),
    }))
    .toSorted(
      (left, right) =>
        Number(right.model.available) - Number(left.model.available) ||
        left.label.localeCompare(right.label),
    );
}

export function availableModelCompanies(choices: ModelChoice[]): ModelCompany[] {
  const companies = new Map<string, ModelCompany>();
  for (const choice of choices) companies.set(choice.company.key, choice.company);
  return [...companies.values()].toSorted((left, right) => left.label.localeCompare(right.label));
}

export function activeModelChoice(
  choices: ModelChoice[],
  selectedModel: string,
): ModelChoice | null {
  return choices.find((choice) => choice.model.id === selectedModel) ?? null;
}

export function routeForChoice(
  choice: ModelChoice,
  selectedRoute: ModelRoute | null,
): ModelRoute | null {
  return (
    choice.routes.find((route) => route.key === selectedRoute?.key && route.route.active) ??
    choice.routes.find(
      (route) => route.key === choice.model.defaultRouteId && route.route.active,
    ) ??
    choice.routes.find((route) => route.route.active) ??
    null
  );
}

export function modelChoiceSearchText(choice: ModelChoice): string {
  return [
    choice.label,
    choice.company.label,
    choice.model.id,
    choice.model.family,
    ...choice.routes.flatMap((route) => [
      route.label,
      route.route.id,
      route.route.rawModelId,
      route.route.controllerName,
    ]),
  ]
    .filter(Boolean)
    .join(" ")
    .toLocaleLowerCase();
}

export function selectedModelRoute(
  models: AgentModel[],
  selectedModel: string,
  selectedRoute?: string,
): ModelRoute | null {
  const model = models.find((candidate) => candidate.id === selectedModel);
  if (!model) return null;
  const choice = buildModelChoices([model])[0];
  if (!choice) return null;
  const route = model.routes.find((candidate) => candidate.id === selectedRoute);
  return route ? { key: route.id, label: route.label, route, model } : routeForChoice(choice, null);
}

function companyFromLab(lab: ModelLab): ModelCompany {
  return {
    key: lab.id,
    label: lab.name,
    ...(lab.logo ? { logo: lab.logo } : {}),
  };
}
