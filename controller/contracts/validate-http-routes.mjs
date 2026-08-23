#!/usr/bin/env node
import { readFile, readdir } from "node:fs/promises";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
const sourceRoot = join(projectRoot, "controller", "src");
const manifestPath = join(projectRoot, "controller", "contracts", "http-routes.json");
const methods = "get|post|put|patch|delete|options";
const effectPattern = new RegExp(`effectRoute\\(\\s*app\\.(${methods})\\s*,\\s*[\"']([^\"']+)[\"']`, "gsu");
const directPattern = new RegExp(`app\\.(${methods})\\(\\s*[\"']([^\"']+)[\"']`, "gsu");

const sourceFiles = async (directory) => {
  const entries = await readdir(directory, { withFileTypes: true });
  const files = await Promise.all(entries.map((entry) => {
    const path = join(directory, entry.name);
    return entry.isDirectory() ? sourceFiles(path) : entry.isFile() && entry.name.endsWith(".ts") ? [path] : [];
  }));
  return files.flat();
};

const keyFor = (method, path) => `${method} ${path}`;
const declarations = new Map();
let declarationCount = 0;

for (const file of await sourceFiles(sourceRoot)) {
  const source = await readFile(file, "utf8");
  const sourcePath = relative(sourceRoot, file).replaceAll("\\", "/");
  for (const match of source.matchAll(effectPattern)) {
    const key = keyFor(match[1].toUpperCase(), match[2]);
    declarations.set(key, [...declarations.get(key) ?? [], sourcePath]);
    declarationCount += 1;
  }
  for (const match of source.matchAll(directPattern)) {
    const preceding = source.slice(Math.max(0, match.index - 32), match.index);
    if (preceding.includes("effectRoute(")) continue;
    const key = keyFor(match[1].toUpperCase(), match[2]);
    declarations.set(key, [...declarations.get(key) ?? [], sourcePath]);
    declarationCount += 1;
  }
}

const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
if (manifest.declarationCount !== declarationCount) {
  throw new Error(`Route declaration count changed: manifest=${manifest.declarationCount}, source=${declarationCount}`);
}
if (manifest.routeCount !== declarations.size || manifest.routes.length !== declarations.size) {
  throw new Error(`Unique route count changed: manifest=${manifest.routeCount}, source=${declarations.size}`);
}

const ownership = new Set(["head", "worker", "shared", "proxied"]);
const streaming = new Set(["always", "conditional", "never"]);
const manifestKeys = new Set();
for (const route of manifest.routes) {
  const key = keyFor(route.method, route.path);
  if (manifestKeys.has(key)) throw new Error(`Duplicate route manifest entry: ${key}`);
  manifestKeys.add(key);
  if (!ownership.has(route.ownership)) throw new Error(`Invalid ownership for ${key}: ${route.ownership}`);
  if (!streaming.has(route.streaming)) throw new Error(`Invalid streaming value for ${key}: ${route.streaming}`);
  const observed = [...declarations.get(key) ?? []].sort();
  const expected = [...route.declarations].sort();
  if (JSON.stringify(observed) !== JSON.stringify(expected)) {
    throw new Error(`Route declarations changed for ${key}: manifest=${expected.join(",")}, source=${observed.join(",")}`);
  }
}

const missing = [...declarations.keys()].filter((key) => !manifestKeys.has(key));
if (missing.length > 0) throw new Error(`Routes missing from manifest: ${missing.join(", ")}`);
console.log(`Controller route manifest matches ${declarationCount} declarations and ${declarations.size} unique routes`);
