import { readFile, writeFile, mkdir } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const contractDirectory = dirname(fileURLToPath(import.meta.url));
const manifestPath = resolve(contractDirectory, "http-routes.json");
const outputPath = resolve(contractDirectory, "../../controller-zig/src/generated/http_routes.zig");

const quote = (value) => JSON.stringify(value);

const render = (manifest) => {
  const routes = manifest.routes.map(
    (route) =>
      `    .{ .method = .${route.method}, .path = ${quote(route.path)}, .ownership = .${route.ownership}, .streaming = .${route.streaming} },`,
  );
  return [
    'const std = @import("std");',
    "",
    "pub const Ownership = enum { head, worker, shared, proxied };",
    "pub const Streaming = enum { never, conditional, always };",
    "",
    "pub const Route = struct {",
    "    method: std.http.Method,",
    "    path: []const u8,",
    "    ownership: Ownership,",
    "    streaming: Streaming,",
    "};",
    "",
    `pub const declaration_count: usize = ${manifest.declarationCount};`,
    `pub const route_count: usize = ${manifest.routeCount};`,
    "",
    "pub const routes = [_]Route{",
    ...routes,
    "};",
    "",
  ].join("\n");
};

const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
const generated = render(manifest);
const mode = process.argv[2] ?? "--check";

if (mode === "--write") {
  await mkdir(dirname(outputPath), { recursive: true });
  await writeFile(outputPath, generated);
} else if (mode === "--check") {
  const existing = await readFile(outputPath, "utf8").catch(() => "");
  if (existing !== generated) {
    console.error("Zig HTTP route registry is stale; run node controller/contracts/generate-zig-http-routes.mjs --write");
    process.exitCode = 1;
  }
} else {
  throw new Error(`Unknown mode: ${mode}`);
}
