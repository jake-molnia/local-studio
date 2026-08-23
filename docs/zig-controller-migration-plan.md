# Zig controller strangler migration

## Migration objective

Replace Local Studio-owned backend services with one `local-studio-controller` Zig executable while preserving the existing HTTP, persistence, filesystem, process-ownership, deployment-result, and frontend contracts. The executable supports `head`, `worker`, and `standalone` modes. The Head migrates first and interoperates with Bun Workers. Worker functionality then moves subsystem by subsystem into one compute architecture.

The frontend and the minimum Electron UI host remain TypeScript. Standalone combines local Head and Worker responsibilities, serves the desktop's local services, and may enroll under a remote Head. Inference engines and agent harnesses such as Pi remain independently installed external programs. Zig discovers them and speaks their supported process or protocol boundary without reimplementing or owning their internal configuration. The Bun controller and Local Studio-owned TypeScript agent service are removed only after their Zig replacements complete live compatibility acceptance.

## Delivery rules

- Preserve existing paths, methods, status codes, response shapes, headers, SSE event names, environment variables, installer marker, and data layouts unless a separate compatibility decision approves a change.
- Keep SQLite and use its C API. Do not replace it with another database.
- Keep provider payloads opaque where Local Studio does not own the schema.
- Give every route one explicit ownership value: `head`, `worker`, `shared`, or `proxied`.
- Use Head-to-Worker HTTP as the only internal network boundary.
- Use typed in-process interfaces between domains.
- Keep engine specifications pure. Specifications produce launch plans and do not install runtimes, mutate instance records, spawn processes, or probe health.
- Keep runtime discovery and installation separate from launching.
- Keep instance records as device and port leases.
- Retry federated inference only before response headers or body bytes are committed.
- Bound every queue, buffer, task registry, retry budget, and shutdown wait.
- Propagate client cancellation to upstream HTTP requests, downloads, installs, and child-process readiness probes.
- Do not add automated tests. Record live acceptance evidence against real processes at the end of every slice.
- Run `npm run check` before handoff.

## Current implementation status

The migration branch starts with a Zig 0.16.0 HTTP foundation under `controller-zig/`.

Completed foundation evidence:

- The compiler is pinned to Zig 0.16.0.
- Official macOS arm64, macOS x86_64, Linux arm64, and Linux x86_64 toolchain archives are identified by fixed SHA-256 values.
- The native binary builds on macOS arm64.
- The binary cross-compiles to Linux x86_64 and Linux arm64.
- `head`, `worker`, and `standalone` configuration values parse from `LOCAL_STUDIO_CONTROLLER_MODE`.
- Configuration owns all environment and command-line strings for the process lifetime and resolves stable data, database, model, and inference paths before application startup.
- Overriding only `LOCAL_STUDIO_DATA_DIR` derives `<data_dir>/controller.db`; a new data directory is created with mode `0700` and its database with mode `0600`.
- `App.init` owns database, shutdown notification, HTTP client, and HTTP server resources with partial-initialization unwind and reverse-order teardown.
- Host and port parse from the existing environment variables.
- `/health` returns `{"status":"ok"}`.
- The HTTP spike streams SSE frames without buffering the complete response.
- Disconnecting an SSE client does not terminate the server.
- SIGTERM while an SSE stream is active cancels the connection task and exits the controller with status zero.
- Invalid and oversized request heads have explicit 400 and 431 response paths.
- Connection tasks are capped at 256; a live 257th concurrent connection received 503 and capacity recovered after the held connections closed.
- Route disposition is explicit for every mode: Head handles shared and Head routes locally, proxies proxied routes, and rejects Worker routes; Worker handles shared, Worker, and proxied routes locally while rejecting Head routes; Standalone handles every route locally.
- Head proxy disposition rejects federation loops, requires a selected Worker, resolves that Worker from the production rig registry, and preserves the existing 409, 404, 502, and 508 failure behavior.
- Application-owned platform discovery captures hostname, operating system, CPU topology, total memory, and Apple Silicon identity behind a Zig boundary shared by Worker and Standalone modes.
- The SQLite C API is loaded dynamically without blocking Linux cross-compilation.
- A copied controller database passes Zig `PRAGMA quick_check`, remains byte-for-byte unchanged, and reopens successfully with Bun.
- The SQLite wrapper owns prepared statements, typed bindings and columns, reset/finalize, multi-statement scripts, change counts, extended errors, and rollback-safe migration transactions.
- A live temporary database probe exercised committed and automatic-rollback transactions, migration rollback after invalid SQL, text, integer, float, blob, null, and constraint-error paths.
- The Zig rigs repository initializes the existing table shape, preserves valid rig documents as opaque JSON, skips malformed documents, and retains Bun's creation-time ordering.
- `GET /studio/rigs` is production-backed in Head, Worker, and Standalone modes. It seeds the default rig, refreshes detected local-node fields, preserves unknown rig and node fields, skips malformed JSON, and persists data that Bun reopens successfully.
- Zig initializes and reads Bun's existing `rig_node_credentials` table without returning API keys to clients. Head derives deduplicated Workers from rig nodes, normalizes their HTTP origins once, and attaches credentials only to federation requests.
- Head `GET /studio/workers` probes model and hardware contracts in parallel with a 16-Worker concurrency ceiling, a three-second deadline per request, and a 4 MiB response limit. Live acceptance covered an authenticated healthy Worker, a hanging Worker, duplicate IDs, concurrent rig reads, secret non-disclosure, and clean shutdown.
- Head forwards selected-Worker management requests with streaming bodies and responses, replaces client credentials with the stored Worker key, adds the federation-hop marker, and returns the selected Worker response header. Live acceptance covered exact query forwarding, a 2 MiB request body, SSE, spoofed-header replacement, credential isolation, and unavailable-Worker behavior.
- Head `GET /v1/models` aggregates healthy Worker catalogs, sorts model IDs, preserves first-seen unknown fields, and merges duplicate availability and context length. Live two-Worker acceptance verified deterministic merging and immediate removal of an unavailable Worker's models.
- Head Chat Completions validates and bounds retryable bodies, selects the least-active healthy Worker serving the requested model, tracks active streams, and retries one alternate only before response commitment. Live overlapping requests selected different Workers, released both counts, preserved request bodies, returned the selected-Worker header, and recovered from a primary connection closed before headers.
- Head inference admission is capped at 16 concurrent requests with a 16 MiB buffered-body ceiling. Missing, invalid, and non-running model requests preserve the existing 400 and `model_not_running` 503 responses.
- Worker and Standalone initialize and read both the current `recipes.data` and legacy `recipes.json` SQLite layouts. Their local `GET /v1/models` catalogs preserve opaque recipe metadata, apply served-name and context defaults, resolve vision capability with the shared precedence rules, skip malformed rows, and report recipes inactive until runtime process observation proves one is serving. Live acceptance covered both schemas and clean shutdown.
- Worker and Standalone read the bounded `instances/llm.json` lease and mark exactly one best-matching recipe active only when the live POSIX PID, process group, session surrogate, start token, and `LOCAL_STUDIO_LAUNCH_NONCE` agree with the persisted process reference. Live macOS acceptance proved an exact record active and the same live PID inactive immediately after only its nonce was changed; both Linux targets compile the `/proc` identity path.
- Worker and Standalone Chat Completions stream through to the configured local inference origin, preserve path/query and opaque payload fields, rewrite a managed recipe ID to its served model name, reject a known inactive recipe with the existing `model_not_running` response, and remove controller `Authorization` and `X-API-Key` credentials before forwarding. Live acceptance covered non-streaming JSON, two-frame SSE, invalid JSON, inactive-model isolation, credential isolation, and both modes against one loopback engine process.
- Worker and Standalone Responses and Anthropic Messages now pass through to the local engine with recipe-to-served-name rewriting, controller credential removal, protocol headers and query preservation, bounded request bodies, and byte-streaming responses. Responses sets the upstream Accept contract from `stream`; live acceptance covered JSON and SSE Responses, Messages with `Anthropic-Version`, opaque fields, validation failures, and confirmed that neither credential header reached the engine.
- Worker and Standalone implement both token-count compatibility transforms over the engine's `/tokenize` API. The routes require a proved active instance, choose the active served model by default, flatten validated text message parts, serialize tools separately, add the four-token per-message overhead, and degrade individual tokenizer failures to zero counts. Live acceptance observed the exact three upstream prompts, verified the `3` and `12` token totals and breakdown, rejected invalid schemas, and returned `No model running` after nonce ownership was revoked.
- Worker and Standalone own recipe reads and writes across both the current `recipes.data` and legacy `recipes.json` layouts. Zig applies the Bun-compatible recipe normalizer at every boundary, preserves legacy aliases and unknown launch arguments, canonicalizes persisted documents, honors the configured trust default, overrides body IDs on path-addressed updates, and keeps delete/not-found behavior stable. Live acceptance covered create, update, delete, invalid input, canonical database contents, and both SQLite layouts.
- Worker and Standalone own the first complete process lifecycle slice for binary, system, and locally discoverable managed runtimes. Zig derives backend argv and environment from canonical recipes, excludes the forbidden vLLM and SGLang flags, probes and reserves the exact port before spawn, persists the null-reference reservation and process lease atomically with mode `0600`, creates a dedicated process group, waits on a bounded health probe, rejects duplicate launches, supports launch cancellation and eviction, and supervises recovered records after restart. Live macOS acceptance covered port-collision rejection without a leaked lease, readiness, active-model visibility, exact nonce/PID/group/start-token recovery after a controller crash, automatic crash reaping, cancellation during readiness, TERM cleanup, and removal of both the child and lease during graceful controller shutdown; both Linux targets compile the same lifecycle path.
- Worker and Standalone expose the supervised lease through `GET /compute/instances` and the canonical named stop and cancel routes. Instance state is derived from reservation presence, exact process ownership, engine health, and the persisted readiness deadline; no status is written to disk. Recovered null-reference reservations retain their one-minute stale window, and port probes tolerate a recently stopped listener while continuing to reject active exact and wildcard bindings. Live acceptance covered empty, reserving, starting, ready, cancelled, stopped, and unknown-name results.
- Worker and Standalone own the frontend `GET /status` contract. Zig reports reservations separately from running processes, rejects stale or identity-mismatched process records, enriches valid processes with canonical recipe model metadata, preserves the configured inference port, and returns the compatibility launch-failure shape. Live Worker and Standalone acceptance covered stopped, running, and stopped-after-eviction transitions.
- Worker and Standalone own `GET /gpus` for Apple Silicon and NVIDIA hosts. Apple Metal reports the stable synthetic device ID and unified-memory semantics without inventing unavailable utilization, thermal, or power measurements; NVIDIA collection uses a bounded `nvidia-smi` query and preserves UUID, PCI identity, memory, utilization, temperature, and power fields. Live Apple M4 acceptance produced the frontend-compatible GPU shape, and absent NVIDIA tooling degrades to an empty list.
- Worker and Standalone own `GET /config` and `GET /compat` with one cancellation-aware, 30-second runtime-discovery cache. Zig reports resolved controller paths and modes, live controller/inference/frontend services, Apple Metal or NVIDIA platform summaries, and bounded discovery for configured or PATH-installed vLLM, SGLang, llama.cpp, and MLX runtimes. Compatibility checks preserve unknown inference-port and no-backend diagnostics. Live acceptance covered configured-runtime detection, exact service and environment payloads, unknown-port evidence, absent-tool degradation, and millisecond cached responses.
- Worker and Standalone own `GET /compute/engines` and `GET /compute/devices`. Engine availability is derived from the host platform, architecture, accelerator, unified-memory model, and the process runtimes Zig can actually supervise; unsupported engines return the canonical reason instead of being advertised. Device snapshots normalize stable accelerator IDs, host memory, swap, kernel release, uptime, and capability-aware nullable measurements. Live Apple M4 acceptance advertised only llama.cpp and MLX, reported the Metal lease ID, and measured reclaimable host memory without treating unified memory as separate VRAM.
- Worker and Standalone own `GET /v1/metrics/vllm`. Zig combines strict owned-process and recipe metadata with local GPU capacity and a bounded Prometheus scrape, normalizing vLLM, SGLang, and llama.cpp counter, queue, cache, throughput, and TTFT names into the frontend contract. A missing, oversized, slow, or non-200 metrics endpoint degrades to the stopped/base shape. Live llama.cpp acceptance verified model metadata, token totals, throughput, queue depth, KV usage, unified-memory capacity, and the post-eviction reset.
- Worker and Standalone own the `/events` SSE dashboard stream. Zig emits status, GPU, and normalized metrics snapshots every five seconds plus the cached runtime, service, and lease summary every thirty seconds, using the existing event envelope and non-buffering headers. Each snapshot is rebuilt from persisted ownership and live probes, and downstream disconnects end the stream without affecting the controller or engine. Live acceptance consumed two cycles with a supervised llama.cpp fixture and verified all four frontend event types.
- Worker and Standalone own log listing, bounded tails, deletion, and live SSE follow across Zig's `instances/logs` files plus the legacy data and temporary `vllm_*.log` locations. Session IDs are path-safe, tails read at most 10 MiB and 20,000 lines, controller-log deletion stays protected, and partial leading lines are dropped. Raw files remain untouched while HTTP and SSE redact authorization headers, environment assignments, JSON keys, CLI flags, and URL parameters, including generic secret-key suffixes. Live acceptance verified recipe metadata, active state, all five redaction forms, a delayed live append, deletion, and traversal-safe rejection.
- Worker and Standalone own `GET` and `POST /studio/settings`. Zig applies persisted model-directory precedence during startup, preserves unknown `studio-settings.json` fields through atomic mode-`0600` updates, serializes concurrent settings access, migrates legacy file-based UI preferences into the existing `controller_settings` table, and keeps `/config` and runtime-summary events synchronized with live directory changes. Live acceptance covered legacy migration, unknown provider and runtime-target fields, relative-path resolution, null clearing, invalid preference rejection, mode `0700`/`0600` hardening, and restart fallback to the configured environment directory.
- Worker and Standalone own `GET /studio/storage`. Zig performs breadth-first, hidden-directory-safe model discovery to the existing depth-two and 200-model limits, recognizes config-only and case-insensitive safetensors, bin, and GGUF layouts, counts only direct weight files for each discovered model, and reports POSIX filesystem capacity with nullable degradation. Directory and entry traversal have additional hard ceilings. Live acceptance discovered nested and config-only layouts, excluded hidden and recursive weight files, produced exact byte totals, and reflected a settings-driven directory switch without restart.
- Worker and Standalone own `GET /studio/diagnostics` and `GET /studio/presets`. Diagnostics combine the process version, ISO sample time, host identity, available memory, frontend-compatible GPU records, cached vLLM discovery, both data and model filesystem capacities, and the live settings directory without exposing credentials. Starter presets preserve the curated payloads, aggregate available accelerator memory, calculate fit flags, and omit the unsupported vLLM lane on Apple Silicon. Live Apple M4 acceptance reported the injected app version, 14-core/24-GiB host, nullable absent-vLLM fields, both mounted paths, and only the llama.cpp and remote starter lanes.
- Worker and Standalone own `POST /studio/models/delete` and `POST /studio/models/move`. Lexically resolved paths must remain under the live models directory, deletion cannot target the root itself, target-root creation is allowed only inside that root, and controller-initiated mutations are serialized. Moves reject collisions, use native rename first, and retain a bounded cross-device recursive copy-and-remove fallback with file permissions and symlinks preserved. Live isolated-tree acceptance proved outside/root rejection, missing-path 404s, collision rejection, exact target reporting, recursive deletion, and unchanged outside files.
- Worker and Standalone own `GET /studio/model-index`. The canonical contract JSON is embedded into the executable directly by the Zig build, while an operator's `<data_dir>/model-index.json` override is bounded, fully schema-validated, and cached by modification time. Invalid JSON and invalid schema retain explicit path-bearing 500 responses. Live acceptance proved the bundled response byte-for-byte identical by SHA-256, served a valid custom tier/model override, and rejected an invalid override without falling back silently.
- Worker and Standalone own `GET /v1/studio/models`. Zig builds de-duplicated configured and absolute recipe-parent roots, scans existing roots through the shared bounded browser, orders models and root provenance deterministically, and associates recipes by canonical path or the existing unique-basename fallback. Each model reports direct weight size, modification time, bounded config architecture/context metadata, quantization inference, and sorted recipe IDs. Live acceptance covered overlapping roots, an external recipe parent, a relative basename match, config-only and weighted models, case-insensitive GGUF inference, exact byte sizes, and deterministic alpha/model-x/z ordering.
- Worker and Standalone own the read-only `/runtime/vllm`, `/runtime/sglang`, `/runtime/llamacpp`, `/runtime/mlx`, `/runtime/cuda`, and `/runtime/rocm` surfaces plus bounded vLLM and llama.cpp config-help probes. Backend responses are projected from the shared cancellation-aware discovery cache; absent CUDA and ROCm degrade to complete nullable contracts. Config help is capped at 5 seconds and 4 MiB. Live acceptance used only PATH-installed-style and explicitly configured external fixtures, detecting all four backend versions and paths while returning exact help output without installing or managing any runtime.
- Worker and Standalone own `GET /runtime/targets` and `POST /runtime/targets/:targetId/select` for the four externally installed engine backends. Target IDs use the existing base64url identity contract, selected IDs persist atomically in `studio-settings.json` without replacing unknown fields, and exact supervised processes also surface as active. Selection access is serialized with studio settings updates while target probes remain read-only. Live acceptance selected a configured SGLang fixture, preserved an unknown nested field, hardened the directory and settings file to modes `0700` and `0600`, returned the canonical 404 for an unknown target, and restored the active selection after controller restart.
- Managed process launches resolve the canonical `<data_dir>/runtime` environment layout and the persisted active external target at launch time. Python-environment references execute the sibling engine entry point rather than Python itself, while explicit binary references remain authoritative and stale or tampered selected paths fall back to managed or PATH discovery. A bounded post-spawn ownership stabilization closes the script-to-interpreter `exec` race before the process lease is admitted. Live acceptance launched MLX first from its managed venv and then from a selected external Python environment, observed the external-runtime marker on the owned process, reached `/v1/models`, and removed the process and lease through eviction.
- Worker and Standalone own `POST /vram-calculator`. Zig validates finite positive context and tensor-parallel inputs, confines resolved model paths to the configured models root, accepts direct model files or direct weight files in a model directory, bounds config metadata reads, and combines weights, KV cache, activation, and fixed overhead estimates with the shared live GPU capacities. Missing dimensions degrade only the KV estimate, while absent GPU capacity retains the compatibility fit default. Live Apple M4 acceptance produced the exact 11-byte weight and 16-KiB FP8 KV calculations and preserved the canonical 400 outside-root, 404 missing-model, and 400 invalid-input responses.
- Worker and Standalone own `POST /benchmark` and `GET /peak-metrics` on Bun's existing SQLite schemas. Benchmarks require strict live process ownership, select the active served model, bound prompt size and upstream response bytes, call only the configured local inference origin, and atomically retain the best generation rate while accumulating completion tokens and request count. Peak reads preserve the single-model error object and deterministic all-model enrichment with best-session columns. Live acceptance observed the exact served model and usage response, rejected an invalid prompt query, accumulated two 30-token runs, kept the better rate, and restored the same row after controller restart; a stopped engine returned the compatibility `No model running` payload without an upstream request.
- Worker and Standalone own runtime job creation, listing, lookup, cancellation, and the legacy backend-upgrade routes. Zig bounds the in-memory registry and captured output, validates the existing request boundary without accepting caller commands or arguments, invalidates runtime discovery after success, and owns every configured upgrade process through a dedicated process group. Cancellation uses a bounded TERM-to-KILL transition, controller shutdown kills active command descendants, and only finished unreferenced jobs are pruned. Live acceptance covered success output, canonical and legacy response shapes, invalid and missing requests, two-second cancellation of a shell with a sleeping descendant, and shutdown with another active installer; no child remained after either path.
- Shared SQLite web access is serialized with a cancellation-aware mutex, while statement and transaction lifetime counters are atomic.
- The compatibility route registry is mechanically generated from all 94 unique manifest routes and matches exact paths and named path segments.
- The reverse-proxy spike forwards methods, paths, queries, end-to-end headers, and request bodies while removing framing and hop-by-hop headers in both directions.
- An 8 MiB request body streamed through the proxy with the exact expected SHA-256 and without whole-body buffering.
- A 64 MiB upstream response feeding a downstream limited to 128 KiB/s increased controller RSS by 464 KiB during the live sample.
- Disconnecting the downstream response canceled the upstream connection while the controller remained healthy.
- A failed primary upstream retried one fallback before response commitment.
- An upstream that failed after response headers were flushed did not retry, returned a truncated response, and left the controller healthy.
- SIGTERM during an active proxy stream canceled the work and exited the controller with status zero.

The migration is not production-ready. Real vLLM and MLX acceptance, GPU placement and leases, Docker supervision, inference usage accounting, remaining SQLite table parity, installer and harness integration, and desktop cutover still require live proof.

## Compatibility ledger

The frozen HTTP, header, SSE, environment, SQLite, filesystem, installer, and process contract is maintained in [zig-controller-compatibility-ledger.md](zig-controller-compatibility-ledger.md) and `controller/contracts/http-routes.json`.

## Work breakdown

### Phase 0: Freeze compatibility

#### 0.1 Route authority

- Keep the checked-in route manifest synchronized with every Bun declaration.
- Add request schema references for Local Studio-owned request bodies.
- Add response schema references for Local Studio-owned payloads.
- Mark opaque provider requests and responses as unmodelled JSON.
- Record status codes and error bodies for each route.
- Record query parameters and path parameter decoding.
- Record whether each route is always, conditionally, or never streaming.
- Record observed Bun ownership separately from desired Zig ownership.
- Generate the OpenAPI document from the language-neutral manifest after parity fields are complete.

#### 0.2 Boundary schemas

- Convert Local Studio payload contracts to JSON Schema.
- Keep provider payloads as arbitrary JSON values.
- Generate TypeScript types used by the frontend.
- Mechanically derive Zig codecs and structures for Local Studio payloads.
- Reject invalid boundary data without duplicating schema definitions in Zig domains.
- Preserve unknown fields in persisted compatibility documents.

#### 0.3 Persistence ledger

- Capture complete table SQL, indexes, migrations, and transaction boundaries.
- Capture database open flags and PRAGMAs.
- Capture malformed-row behavior for every JSON payload table.
- Capture file modes and atomic-write sequences.
- Capture all credential filenames without recording credential values.
- Capture runtime-target persistence and managed-environment directory names.
- Capture download target and temporary-file naming.

#### 0.4 Process ledger

- Capture launch environment construction per engine.
- Capture argument normalization and omission rules.
- Capture process group and session creation per platform.
- Capture PID/start-token/nonce ownership checks.
- Capture TERM, grace, KILL, and polling durations.
- Capture Docker labels, names, daemon identity, and pending-container recovery.
- Capture startup recovery and stale-record decisions.

#### 0.5 Phase acceptance

- Review all 96 declarations against the manifest.
- Export a live Bun `/api/spec` and compare paths and methods.
- Exercise every SSE surface long enough to observe heartbeats.
- Open a copied production data directory without mutation beyond current Bun migrations.
- Document current bugs as compatibility facts.

### Phase 1: Zig foundation

#### 1.1 Toolchain and build

- Keep Zig pinned to 0.16.0.
- Verify official archives by SHA-256 before extraction.
- Build native debug and release binaries.
- Cross-compile Linux x86_64 and Linux arm64 artifacts.
- Add macOS arm64 release packaging.
- Add `zig build` to `npm run check` and CI.
- Record compiler upgrade decisions separately from feature changes.

#### 1.2 Application ownership

- Implement `App.init` and reverse-order `App.deinit`.
- Give every resource one owner.
- Make partial initialization unwind safely.
- Separate configuration, repositories, HTTP, federation, inference, compute, runtimes, downloads, events, and telemetry.
- Use error unions at domain boundaries.
- Avoid global mutable state except signal-safe shutdown notification.

#### 1.3 Configuration

- Parse every existing controller environment variable.
- Apply the same defaults and path resolution.
- Preserve keyless-host and wildcard-host startup guards.
- Parse persisted settings without dropping unknown fields.
- Keep secrets out of structured logs and diagnostics.

#### 1.4 HTTP server

- Replace spike-only routes with the contract route registry.
- Implement exact method and path-parameter matching.
- Implement ordered middleware for runtime context, keyless authority, CORS, observability, rate limiting, authentication, and federation.
- Bound request-head and request-body resources.
- Return intentional 400, 404, 413, 431, 499, and 500 behavior.
- Stream request and response bodies incrementally.
- Stop reading upstream when the downstream disconnects.
- Stop writing downstream when upstream cancellation wins.
- Support keep-alive without retaining request-scoped memory.
- Add connection, header, body-idle, and total deadlines.

#### 1.5 Cancellation and tasks

- Implement a cancellation token with idempotent cancellation.
- Implement bounded task registration with names and shutdown classes.
- Reject new work after shutdown begins.
- Cancel network probes and streams before repositories close.
- Stop child processes before instance stores close.
- Give each shutdown class a bounded deadline.
- Emit remaining task names when a shutdown deadline expires.

#### 1.6 SQLite C API

- Load the platform SQLite library and resolve the required C API explicitly.
- Wrap open, close, prepare, bind, step, reset, finalize, transaction, and error extraction.
- Apply `busy_timeout = 5000`.
- Preserve current schemas and migrations.
- Keep statement ownership explicit.
- Roll back transactions on every error path.
- Validate against a copied production database.

#### 1.7 Foundation acceptance

- Hold at least one SSE connection for 30 minutes.
- Disconnect clients during headers, request body, and response body.
- Proxy a large streaming body through a deliberately slow consumer.
- Send malformed, truncated, and oversized request heads.
- Send SIGTERM with idle, SSE, proxy, SQLite, download, and child-process work active.
- Confirm zero exit after bounded cleanup.
- Reopen copied data with Bun after Zig exits.

### Phase 2: Zig Head with Bun Workers

#### 2.1 Repositories

- Open rigs without rewriting JSON payloads.
- Load Worker credentials without returning them through APIs.
- Open inference usage and session metadata tables.
- Preserve event IDs and origin controller IDs.
- Keep Codex and Cursor subscription integrations in a Bun sidecar until their long-term boundary is decided.

#### 2.2 Worker registry and health cache

- Derive Workers from rig node roles.
- Normalize controller addresses exactly once.
- Attach Worker API keys only to outbound requests.
- Probe health, models, hardware, events, and logs with explicit deadlines.
- Run probes in parallel under a bounded concurrency limit.
- Mark cached state with collection and expiry timestamps.
- Never use stale health as mutation success.

#### 2.3 Explicit route ownership

- Replace `HEAD_PATHS` with generated route ownership.
- Handle `shared` routes locally in every mode.
- Handle `head` routes locally on Head.
- Handle `proxied` routes locally on Worker and standalone, and forward them from Head.
- Reject Worker-only routes on Head if any are introduced.
- Reject federation loops before outbound Worker lookup.
- Require a selected Worker only for `proxied` routes.

#### 2.4 Inference router

- Parse model identity without modelling opaque provider payloads.
- Build eligible local, Worker, and configured-provider upstream sets.
- Select healthy Workers serving the model.
- Track active streams with release on success, error, and cancellation.
- Choose the least-active eligible Worker with deterministic tie-breaking.
- Establish one response-commitment boundary shared by all dialects.
- Retry one different Worker only before commitment.
- Preserve the existing `model_not_running` error when no eligible upstream exists.

#### 2.5 Protocol adapters

- Implement OpenAI Chat Completions streaming and non-streaming forwarding.
- Implement OpenAI Responses streaming and non-streaming forwarding.
- Implement Anthropic Messages streaming and non-streaming forwarding.
- Preserve dialect-specific headers and event names.
- Normalize usage only where the existing controller does so.
- Keep unknown fields and events intact.

#### 2.6 Management proxy

- Forward method, path, query, headers, and body incrementally.
- Add the federation-hop marker.
- Remove hop-by-hop headers in both directions.
- Attach Worker authentication without exposing it downstream.
- Set the selected Worker response header.
- Preserve Worker status and error bodies when the Worker responds.
- Use Worker-specific 404, 409, 502, and loop 508 behavior.

#### 2.7 Usage, sessions, events, and logs

- Record centralized usage after final upstream selection.
- Import Worker outbox events idempotently by event ID.
- Persist session metadata without transcripts.
- Relay Worker controller events without unbounded buffering.
- Relay Worker logs with the existing redaction boundary.
- Cancel Worker streams when desktop clients disconnect.

#### 2.8 Head acceptance

- Run unchanged desktop against Zig Head and Bun Worker processes.
- Exercise management reads and mutations for a selected Worker.
- Stream Worker events and logs through Head.
- Aggregate models from multiple Workers.
- Exercise Chat, Responses, and Messages in streaming and non-streaming forms.
- Demonstrate least-active selection with concurrent streams.
- Kill the selected Worker before commitment and observe one retry.
- Kill it after commitment and observe stream failure without retry.
- Restart Head and verify usage and sessions persist.

### Phase 3: Unified Worker compute core

#### 3.1 Domain model

- Port the destination `compute/` contracts.
- Define one engine ID model.
- Define one runtime-target model.
- Define one launch-plan model.
- Define one instance-record model.
- Keep `ComputeBridge` behavior only as a temporary compatibility checklist.

#### 3.2 Engine specifications

- Make vLLM and MLX specifications pure first.
- Produce argv, environment, runtime kind, ports, devices, readiness probe, and stop policy.
- Preserve forbidden argument policy: never add `disable cuda graphs`, `enforce eager`, or `max_tokens`.
- Preserve tool parser, reasoning parser, trust-remote-code, expert-parallel, and extra-argument normalization.
- Keep custom launch commands behind the existing opt-in variable.

#### 3.3 Instance store and placement

- Read every existing handle-reference variant.
- Reproduce atomic writes and permissions.
- Reproduce placement lock acquisition and stale-holder behavior.
- Reserve records before spawn.
- Derive held devices from live records.
- Reproduce unified-memory sharing rules.
- Reproduce exact-port and scanned-port allocation.

#### 3.4 Process launcher

- Spawn a dedicated process group or platform equivalent.
- Persist PID, process group, session, start token, and nonce.
- Capture stdout and stderr into the existing log path.
- Verify ownership before every signal.
- Implement TERM, grace, KILL.
- Keep raw logs on disk and redact serialized tails.

#### 3.5 Docker launcher

- Preserve pending records before container creation.
- Attach nonce and ownership labels.
- Record daemon and executable identity.
- Recover or remove pending containers safely.
- Verify ownership before stop or removal.
- Keep Docker optional and discoverable independently of engine support.

#### 3.6 Supervisor

- Run one reaper loop per node.
- Drop dead records and release capacity by record deletion.
- Reconcile records on startup before accepting launches.
- Cancel readiness probes when launches are cancelled.
- Keep crash reaping independent of HTTP request lifetimes.

#### 3.7 Initial engines

- Implement vLLM process launch on Linux.
- Implement vLLM readiness, inference, cancellation, eviction, recovery, and crash reaping.
- Implement MLX process launch on Apple Silicon.
- Implement MLX readiness, inference, cancellation, eviction, recovery, and crash reaping.
- Preserve exact inference-port behavior for the legacy single `llm` instance.

#### 3.8 Compute acceptance

- Launch against real vLLM on Linux.
- Launch against real MLX on Apple Silicon.
- Cancel before spawn, during spawn, and during readiness.
- Restart Zig while an owned engine remains alive.
- Confirm ownership recovery without duplicate launch.
- Simulate PID reuse mismatch and refuse termination.
- Crash the engine and observe record reaping.
- Read and stream logs through the unchanged frontend.

### Phase 4: Runtime and engine parity

- Add SGLang process and Docker plans.
- Add llama.cpp binary discovery and process plans.
- Add managed Python environment discovery.
- Add configured, discovered, bundled, managed, binary, system, and Docker targets.
- Persist selected target IDs without losing unknown settings.
- Add cancellable install and update jobs.
- Add CUDA and ROCm information and upgrade hooks.
- Preserve parser defaults and recipe serialization.
- Preserve custom-command behavior.
- Do not add exllamav3 launching.

Acceptance uses real SGLang and llama.cpp processes plus runtime install cancellation and restart recovery.

### Phase 5: Operational services

- Port Hugging Face metadata and resumable Range downloads.
- Preserve `.part` files and completed-byte accounting.
- Bound download buffers and concurrent files.
- Propagate pause and cancel into active HTTP reads.
- Port model discovery, move, and delete operations.
- Port GPU, host, storage, and thermal probes behind platform interfaces.
- Port Prometheus parsing and lifetime/peak aggregation.
- Port logs, retention, redaction, tailing, and SSE.
- Port settings, diagnostics, compatibility, presets, and VRAM estimation.
- Port authority validation, CORS, authentication, and rate limiting.
- Generate OpenAPI and serve documentation.

Acceptance exercises each service through the unchanged frontend against real files, hardware tools, and inference runtimes.

### Phase 6: Deployment and cutover

- Produce versioned macOS arm64, Linux x86_64, and Linux arm64 binaries.
- Generate release checksums.
- Update the installer to download and verify a binary.
- Preserve data and models directories.
- Preserve API-key reuse and generation.
- Preserve launchd label, systemd behavior, restart policy, logs, and completion marker.
- Validate Zig Head to Bun Worker.
- Validate Bun Head to Zig Worker where feasible.
- Validate Zig Head to Zig Worker.
- Validate existing data to Zig and rollback to Bun.
- Make Zig the default for one release cycle.
- Remove Bun controller code only after the compatibility window closes.

## Swarm execution model

The coordinator owns contracts, architecture decisions, integration, live evidence, and final commits. Agent work is divided into independent read-only or tightly scoped implementation lanes:

1. Contract ledger and schema extraction.
2. Zig HTTP, cancellation, and toolchain review.
3. Head federation and inference routing.
4. Worker compute and process safety.
5. SQLite and filesystem compatibility.
6. Runtime discovery and installation.
7. Downloads and operational services.
8. Deployment and packaging.

At most four agents run concurrently. Additional lanes queue behind them. Agent reports are treated as proposals until the coordinator verifies cited code, reconciles conflicts, runs the applicable live acceptance, and updates this plan. Agents do not create competing contract definitions and do not add tests.

## Commit sequence

1. `docs(controller): freeze Zig migration compatibility surface`
2. `build(controller): pin Zig 0.16 toolchain`
3. `feat(controller): add Zig HTTP foundation`
4. `feat(controller): add SQLite compatibility repository`
5. `feat(controller): add explicit route registry`
6. `feat(controller): add Zig Worker registry`
7. `feat(controller): aggregate Bun Worker models`
8. `feat(controller): route inference through Bun Workers`

Each commit remains buildable. The first pull request should stop after a verified foundation and a narrow Zig Head vertical slice; it should not include Worker compute implementation.
