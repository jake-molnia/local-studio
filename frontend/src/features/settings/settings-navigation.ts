export type SettingsDestination =
  | "profile"
  | "connection"
  | "controller"
  | "system"
  | "appearance"
  | "terminal"
  | "archive"
  | "setup"
  | "machines"
  | "machine:local:usage"
  | "machine:local:logs";

export const settingsHref = (destination: SettingsDestination | string = "connection"): string =>
  `/settings#${destination}`;

export const legacySettingsHash = (hash: string): string | null => {
  if (hash === "desktop") return "terminal";
  if (hash === "engines" || hash === "services") return "system";
  if (hash === "rig" || hash === "machines") return "machines";
  if (hash === "usage") return "machine:local:usage";
  if (hash === "logs") return "machine:local:logs";
  return null;
};
