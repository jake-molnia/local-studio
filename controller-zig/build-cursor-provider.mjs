#!/usr/bin/env bun
import { copyFile, mkdir } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const controller = resolve(root, "controller");
const outputDirectory = resolve(root, "controller-zig", "src", "assets");
const aliases = new Map([
  ["effect", resolve(controller, "node_modules/effect/dist/index.js")],
  [
    "@rahularya01/pi-cursor",
    resolve(controller, "node_modules/@rahularya01/pi-cursor/dist/index.js"),
  ],
  ["@earendil-works/pi-ai", resolve(root, "controller-zig/cursor-provider-shims/pi-ai.ts")],
  [
    "@earendil-works/pi-ai/compat",
    resolve(root, "controller-zig/cursor-provider-shims/pi-ai-compat.ts"),
  ],
  [
    "@earendil-works/pi-coding-agent",
    resolve(root, "controller-zig/cursor-provider-shims/pi-coding-agent.ts"),
  ],
]);

await mkdir(outputDirectory, { recursive: true });
const result = await Bun.build({
  entrypoints: [resolve(root, "controller-zig/cursor-provider-bridge.ts")],
  outdir: outputDirectory,
  naming: "cursor-provider.mjs",
  target: "node",
  format: "esm",
  minify: true,
  plugins: [
    {
      name: "cursor-provider-shims",
      setup(build) {
        build.onResolve({ filter: /^(?:effect|@rahularya01\/pi-cursor)$/ }, ({ path }) => ({
          path: aliases.get(path),
        }));
        build.onResolve({ filter: /^@earendil-works\/pi-ai(?:\/compat)?$/ }, ({ path }) => ({
          path: aliases.get(path),
        }));
        build.onResolve({ filter: /^@earendil-works\/pi-coding-agent$/ }, ({ path }) => ({
          path: aliases.get(path),
        }));
      },
    },
  ],
});
if (!result.success) throw new Error("Cursor provider bundle failed");
await copyFile(
  resolve(controller, "node_modules/@rahularya01/pi-cursor/dist/h2-bridge.mjs"),
  resolve(outputDirectory, "h2-bridge.mjs"),
);
