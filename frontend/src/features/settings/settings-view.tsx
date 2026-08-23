"use client";
import { useState } from "react";
import {
  Archive,
  Cable,
  Cpu,
  Keyboard,
  type LucideIcon,
  Paintbrush,
  ServerCog,
  Smartphone,
} from "@/ui/icon-registry";
import {
  SettingsLayout,
  type SettingsSearchEntry,
  type SettingsSectionDef,
  type SettingsSectionId,
} from "./settings-ui";
import type { CompatibilityReport, ConfigData } from "@/lib/types";
import type { ApiConnectionSettings, ConnectionStatus } from "./types";
import { ApiConnectionSection } from "./api-connection-section";
import { ArchivedChatsSettings, SetupChecksSettings } from "./agent-settings-sections";
import { AppearanceSettings } from "./appearance-settings";
import { ShortcutsSettings } from "./terminal-settings";
import { EnginesSection } from "./engines-section";
import { ServicesSettings, SystemDetails, SystemOverview } from "./system-settings-section";
import { useMountSubscription } from "@/hooks/use-mount-subscription";
import { ProfileSettings } from "./profile-settings";
interface SettingsViewProps {
  data: ConfigData | null;
  compatibilityReport: CompatibilityReport | null;
  loading: boolean;
  error: string | null;
  apiSettings: ApiConnectionSettings;
  apiSettingsLoading: boolean;
  saving: boolean;
  testing: boolean;
  connectionStatus: ConnectionStatus;
  statusMessage: string;
  onReload: () => void;
  onApiSettingsChange: (nextSettings: ApiConnectionSettings) => void;
  onTestConnection: () => void;
  onSaveSettings: () => void;
  onSystemSectionActive: () => void;
}
const sectionIcon = (Icon: LucideIcon) => <Icon className="h-3.5 w-3.5" />;
const SETTINGS_SEARCH_ENTRIES: Record<string, readonly SettingsSearchEntry[]> = {
  profile: [
    { label: "Your profile", terms: ["name", "avatar", "image", "color", "identity"] },
    {
      label: "Connect your phone",
      terms: ["pairing", "qr", "kittylitter", "download", "connection json"],
    },
  ],
  connection: [
    { label: "Application", terms: ["release", "updates", "desktop"] },
    { label: "Update channel", terms: ["stable", "nightly"] },
    { label: "Version", terms: ["build", "release", "web ui"] },
    {
      label: "Local controller",
      terms: ["controller name", "controller url", "endpoint", "api key", "censor urls"],
    },
    { label: "Active connection check", terms: ["test", "probe", "save active"] },
  ],
  system: [
    { label: "Services & endpoints", terms: ["controller", "service", "health", "url"] },
    { label: "Runtime engines", terms: ["vllm", "sglang", "llama", "engine"] },
    { label: "Host", target: "Runtime engines", terms: ["runtime host"] },
    { label: "GPU monitoring", target: "Runtime engines", terms: ["nvidia", "metrics"] },
    { label: "GPU lease", target: "Runtime engines", terms: ["allocation", "reservation"] },
    {
      label: "Managed environments",
      target: "Runtime engines",
      terms: ["environment", "runtime"],
    },
    {
      label: "Discovered runtimes",
      target: "Runtime engines",
      terms: ["runtime", "discovery"],
    },
    { label: "Machine details", terms: ["platform", "gpu", "storage", "hardware"] },
    { label: "Compatibility", terms: ["requirements", "support"] },
  ],
  appearance: [
    { label: "Theme", terms: ["light", "dark", "system", "mode"] },
    { label: "Active theme", terms: ["preset", "palette"] },
    { label: "Theme library", terms: ["presets", "colors", "fonts"] },
    { label: "Accent", target: "Accent", terms: ["highlight", "links", "buttons"] },
    { label: "Background", target: "Background", terms: ["canvas", "color"] },
    { label: "Foreground", target: "Foreground", terms: ["text", "color"] },
    { label: "Surface", target: "Surface", terms: ["cards", "panels", "color"] },
    { label: "Font family", terms: ["typeface", "typography"] },
    { label: "UI font size", terms: ["text", "typography"] },
    { label: "UI scale", terms: ["zoom", "density"] },
    { label: "Corner radius", terms: ["roundness", "shape"] },
    { label: "Chat text size", terms: ["message", "composer", "font"] },
    { label: "Chat line height", terms: ["leading", "spacing"] },
    { label: "Chat column width", terms: ["thread", "composer", "width"] },
    { label: "Bubble tone", terms: ["message", "surface", "color"] },
    { label: "All tools", terms: ["preview", "height"] },
  ],
  terminal: [
    { label: "Global hotkey", terms: ["quick panel", "keyboard", "shortcut"] },
    {
      label: "Terminal key bindings",
      terms: ["copy", "paste", "search", "clear", "new terminal", "shortcut"],
    },
    { label: "Font size", terms: ["terminal text", "pixels"] },
  ],
  archive: [{ label: "Archived chats", terms: ["hidden", "sessions", "restore", "tasks"] }],
  setup: [
    {
      label: "First-time setup",
      terms: ["preflight", "prerequisite", "controller connection", "requirements"],
    },
  ],
};
const SECTIONS: SettingsSectionDef[] = [
  [
    "profile",
    "Profile & phone",
    "Your identity and phone pairing.",
    Smartphone,
    "name avatar image color phone pairing qr kittylitter download connection json",
  ],
  [
    "connection",
    "General",
    "Controller connections and API access.",
    Cable,
    "controller api endpoint url key connection version release update censor",
  ],
  [
    "system",
    "System",
    "Engines, services, storage, and hardware.",
    Cpu,
    "engine vllm sglang llama runtime service hardware gpu storage cache environment host lease monitoring",
  ],
  [
    "appearance",
    "Appearance",
    "Theme, typography, and interface scale.",
    Paintbrush,
    "theme color token typography font family ui font size scale corner radius chat text line height column width bubble tone tools",
  ],
  [
    "terminal",
    "Shortcuts",
    "Quick panel and terminal key bindings.",
    Keyboard,
    "keyboard keybinding shortcut terminal quick panel terminal font size reset keys",
  ],
  [
    "archive",
    "Archived chats",
    "Sessions hidden from the task list.",
    Archive,
    "archived hidden chats tasks sessions restore delete",
  ],
  [
    "setup",
    "Setup",
    "Local prerequisites and first-run checks.",
    ServerCog,
    "prerequisite check install first run local environment requirements",
  ],
].map(([id, label, description, Icon, searchTerms]) => ({
  id: id as SettingsSectionId,
  label: label as string,
  description: description as string,
  icon: sectionIcon(Icon as LucideIcon),
  searchTerms: [searchTerms as string],
  settings: SETTINGS_SEARCH_ENTRIES[id as string] ?? [],
}));
const isSectionId = (value: string): value is SettingsSectionId =>
  SECTIONS.some((section) => section.id === value);
const normalizeSectionId = (value: string): SettingsSectionId | null => {
  if (isSectionId(value)) return value;
  if (value === "desktop") return "terminal";
  if (value === "engines" || value === "services") return "system";
  return null;
};
export function SettingsView({
  data,
  compatibilityReport,
  loading,
  error,
  apiSettings,
  apiSettingsLoading,
  saving,
  testing,
  connectionStatus,
  statusMessage,
  onReload,
  onApiSettingsChange,
  onTestConnection,
  onSaveSettings,
  onSystemSectionActive,
}: SettingsViewProps) {
  const [activeSection, setActiveSection] = useState<SettingsSectionId>("connection");
  useMountSubscription(() => {
    const onHashChange = () => {
      const hash = window.location.hash.replace("#", "");
      if (["connectors", "plugins", "accounts", "access", "models", "skills"].includes(hash)) {
        window.location.replace(`/customize#${hash}`);
        return;
      }
      const normalized = normalizeSectionId(hash);
      if (!normalized) return;
      setActiveSection(normalized);
      if (normalized === "system") onSystemSectionActive();
    };
    onHashChange();
    window.addEventListener("hashchange", onHashChange);
    return () => window.removeEventListener("hashchange", onHashChange);
  }, []);
  const selectSection = (section: SettingsSectionId) => {
    setActiveSection(section);
    if (section === "system") onSystemSectionActive();
    if (typeof window !== "undefined") {
      window.history.replaceState(null, "", `#${section}`);
    }
  };
  return (
    <SettingsLayout
      sections={SECTIONS}
      activeSection={activeSection}
      title="Settings"
      loading={loading}
      takeover
      onReload={onReload}
      onSelectSection={selectSection}
    >
      {activeSection === "connection" ? (
        <ApiConnectionSection
          apiSettingsLoading={apiSettingsLoading}
          apiSettings={apiSettings}
          testing={testing}
          saving={saving}
          connectionStatus={connectionStatus}
          statusMessage={statusMessage}
          onApiSettingsChange={onApiSettingsChange}
          onTestConnection={onTestConnection}
          onSave={onSaveSettings}
        />
      ) : null}
      {activeSection === "profile" ? <ProfileSettings /> : null}
      {activeSection === "system" ? (
        <div className="space-y-5">
          <SystemOverview
            data={data}
            compatibilityReport={compatibilityReport}
            loading={loading}
            error={error}
          />
          <EnginesSection runtime={data?.runtime ?? null} />
          <ServicesSettings data={data} apiSettings={apiSettings} loading={loading} error={error} />
          <SystemDetails data={data} compatibilityReport={compatibilityReport} />
        </div>
      ) : null}
      {activeSection === "appearance" ? <AppearanceSettings /> : null}
      {activeSection === "terminal" ? <ShortcutsSettings /> : null}
      {activeSection === "archive" ? <ArchivedChatsSettings /> : null}
      {activeSection === "setup" ? <SetupChecksSettings /> : null}
    </SettingsLayout>
  );
}
