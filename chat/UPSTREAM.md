# Chat runtime upstream

The embedded Chat runtime is a pruned fork of [vercel-labs/fx](https://github.com/vercel-labs/fx) at commit `669ef8a7f0bf6b13a1722bfd434fb9fc61d01511`.

The retained source is the dependency closure used by `src/main.zig` plus the native filesystem tool implementations in `src/tools/filesystem`. Filesystem tools are intentionally disabled by `src/tool_policy.zig` until Chat sessions run inside an isolated filesystem sandbox.

The FX ACP server, terminal UI, SDKs, WASM and N-API entrypoints, benchmarks, release automation, and unrelated built-in tools are not part of this fork. A separately installed `fx` executable remains an external harness discovered by the controller.
