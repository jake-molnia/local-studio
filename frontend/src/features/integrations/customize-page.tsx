"use client";

import { useState } from "react";
import { useMountSubscription } from "@/hooks/use-mount-subscription";
import { AppPage, SearchInput } from "@/ui";
import { Brain, GraduationCap, KeyRound, Plug, Puzzle, ShieldCheck } from "@/ui/icon-registry";
import { cx } from "@/ui/utils";
import { ConnectorsSection } from "./connectors-section";
import { ConnectorAccessSection } from "./connector-access-section";
import { GoogleAccountsSection } from "./google-accounts-section";
import { integrationSectionFromHash, type IntegrationSectionId } from "./integration-navigation";
import { ModelProvidersSection } from "./model-providers-section";
import { PluginsSection } from "./plugins-section";
import { SkillsSection } from "./skills-section";

const CATEGORIES = [
  { id: "plugins", label: "Plugins", icon: Puzzle, description: "Agent extensions" },
  { id: "connectors", label: "MCPs", icon: Plug, description: "Servers and tools" },
  { id: "skills", label: "Skills", icon: GraduationCap, description: "Session instructions" },
  { id: "accounts", label: "Accounts", icon: KeyRound, description: "Connected accounts" },
  { id: "models", label: "Models", icon: Brain, description: "Provider sign-in" },
  { id: "access", label: "Access", icon: ShieldCheck, description: "Model permissions" },
] satisfies Array<{
  id: IntegrationSectionId;
  label: string;
  icon: typeof Plug;
  description: string;
}>;

function CustomizeSection({ section, query }: { section: IntegrationSectionId; query: string }) {
  if (section === "connectors") return <ConnectorsSection searchQuery={query} />;
  if (section === "plugins") return <PluginsSection searchQuery={query} />;
  if (section === "accounts") return <GoogleAccountsSection searchQuery={query} />;
  if (section === "access") return <ConnectorAccessSection searchQuery={query} />;
  if (section === "models") return <ModelProvidersSection searchQuery={query} />;
  return <SkillsSection searchQuery={query} />;
}

export function CustomizePage() {
  const [section, setSection] = useState<IntegrationSectionId>(() =>
    integrationSectionFromHash(""),
  );
  const [query, setQuery] = useState("");

  useMountSubscription(() => {
    const syncSection = () => setSection(integrationSectionFromHash(window.location.hash));
    syncSection();
    window.addEventListener("hashchange", syncSection);
    return () => window.removeEventListener("hashchange", syncSection);
  }, []);

  const selectSection = (next: IntegrationSectionId) => {
    setSection(next);
    setQuery("");
    window.history.replaceState(null, "", `/customize#${next}`);
  };

  return (
    <AppPage>
      <div className="mx-auto flex min-h-full w-full max-w-[34rem] flex-col px-4 pb-12 pt-7 sm:px-5">
        <header className="w-full">
          <h1 className="sr-only">Customize</h1>
          <SearchInput
            value={query}
            onChange={setQuery}
            placeholder="Search plugins, skills, MCPs..."
            aria-label="Search plugins, skills, and MCPs"
            className="w-full [&_input]:h-7 [&_input]:rounded-[5px] [&_input]:bg-(--ui-surface) [&_input]:text-[length:var(--fs-xs)]"
          />
        </header>

        <nav aria-label="Customize categories" className="mt-3 w-full overflow-x-auto">
          <div className="flex min-w-max items-center gap-1">
            {CATEGORIES.map(({ id, label, description }) => {
              const active = section === id;
              return (
                <button
                  key={id}
                  type="button"
                  aria-current={active ? "page" : undefined}
                  onClick={() => selectSection(id)}
                  className={cx(
                    "group inline-flex h-6 items-center rounded-full border px-2 text-[length:var(--fs-xs)] font-normal transition-[background-color,border-color,color] focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-(--ui-accent)/40",
                    active
                      ? "border-(--ui-border-heavy) bg-(--ui-active) text-(--ui-fg)"
                      : "border-(--ui-separator) bg-(--ui-surface)/45 text-(--ui-muted) hover:border-(--ui-border-heavy) hover:bg-(--ui-hover) hover:text-(--ui-fg)",
                  )}
                  title={description}
                >
                  <span>{label}</span>
                </button>
              );
            })}
          </div>
        </nav>

        <section
          aria-label="Customize results"
          data-customize-surface
          className="mt-5 w-full min-w-0"
        >
          <CustomizeSection section={section} query={query.trim()} />
        </section>
      </div>
    </AppPage>
  );
}
