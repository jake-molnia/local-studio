# Zig controller strangler migration

## Migration objective

Replace the Bun/Hono controller with one `local-studio-controller` Zig executable while preserving the existing HTTP, persistence, filesystem, process-ownership, deployment-result, and frontend contracts. The executable supports `head`, `worker`, and `standalone` modes. The Head migrates first and interoperates with Bun Workers. Worker functionality then moves subsystem by subsystem into one compute architecture.

The frontend, Electron shell, agent runtime, inference engines, bundled model index, and frontend-facing TypeScript contracts remain outside the rewrite.

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
- Host and port parse from the existing environment variables.
- `/health` returns `{"status":"ok"}`.
- The HTTP spike streams SSE frames without buffering the complete response.
- Disconnecting an SSE client does not terminate the server.
- SIGTERM while an SSE stream is active cancels the connection task and exits the controller with status zero.
- Invalid and oversized request heads have explicit 400 and 431 response paths.
- The SQLite C API is loaded dynamically without blocking Linux cross-compilation.
- A copied controller database passes Zig `PRAGMA quick_check`, remains byte-for-byte unchanged, and reopens successfully with Bun.
- The compatibility route registry is mechanically generated from all 94 unique manifest routes and matches exact paths and named path segments.
- The reverse-proxy spike forwards methods, paths, queries, end-to-end headers, and request bodies while removing framing and hop-by-hop headers in both directions.
- An 8 MiB request body streamed through the proxy with the exact expected SHA-256 and without whole-body buffering.
- A 64 MiB upstream response feeding a downstream limited to 128 KiB/s increased controller RSS by 464 KiB during the live sample.
- Disconnecting the downstream response canceled the upstream connection while the controller remained healthy.
- A failed primary upstream retried one fallback before response commitment.
- An upstream that failed after response headers were flushed did not retry, returned a truncated response, and left the controller healthy.
- SIGTERM during an active proxy stream canceled the work and exited the controller with status zero.

The spike is not production-ready. Bounded task admission, timeouts, production Worker selection and authentication, full SQLite statement and transaction parity, and shutdown with child processes still require live proof.

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
