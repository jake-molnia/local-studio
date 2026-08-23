# Zig controller compatibility ledger

This ledger freezes the observed Bun controller boundary for the Zig strangler migration. Route authority is machine-readable in `controller/contracts/http-routes.json`. Changes to observed behavior require an explicit compatibility decision and live acceptance evidence.

## Compatibility sources

`controller/contracts/http-routes.json` is the initial route ledger. It records 96 declarations representing 94 unique method/path combinations. The duplicate declarations are:

- `POST /v1/chat/completions`: federation and local OpenAI proxy implementations.
- `GET /v1/models`: federation and local model implementations.

The ledger records observed Bun Head ownership, including current inconsistencies. It must not be silently changed to the desired Zig ownership model.

Additional contract sources remain:

- `controller/contracts/controller-events.ts`
- `controller/contracts/federation.ts`
- `controller/contracts/observability.ts`
- `controller/contracts/provider-auth.ts`
- `controller/contracts/recipes.ts`
- `controller/contracts/rigs.ts`
- `controller/contracts/system.ts`
- `controller/contracts/usage-schema.ts`
- `controller/contracts/usage.ts`

## Compatibility inventory

### HTTP headers

Inbound authentication and protocol headers:

- `Authorization`
- `X-API-Key`
- `Anthropic-Version`
- `Anthropic-Beta`
- `OpenAI-Beta`
- `Content-Type`

Federation headers:

- `X-Local-Studio-Worker-Id`
- `X-Local-Studio-Federation-Hop`

Rate-limit and authentication response headers:

- `WWW-Authenticate`
- `X-RateLimit-Limit`
- `X-RateLimit-Remaining`
- `X-RateLimit-Reset`
- `Retry-After`

Streaming and proxy response headers:

- `Content-Type: text/event-stream`
- `Cache-Control: no-cache, no-transform`
- `Connection: keep-alive`
- `X-Accel-Buffering: no`

The management proxy removes hop-by-hop `connection`, `content-length`, and `transfer-encoding` response headers before constructing the downstream response. It adds the selected Worker ID response header.

### SSE contract

Controller event names:

- `status`
- `gpu`
- `metrics`
- `runtime_summary`
- `launch_progress`
- `model_switch`
- `download_progress`
- `download_state`
- `recipe_created`
- `recipe_updated`
- `recipe_deleted`
- `rig_updated`
- `mcp_server_created`
- `mcp_server_updated`
- `mcp_server_deleted`
- `mcp_server_enabled`
- `mcp_server_disabled`
- `mcp_tool_called`
- `runtime_vllm_upgraded`
- `runtime_sglang_upgraded`
- `runtime_llamacpp_upgraded`
- `runtime_cuda_upgraded`
- `runtime_rocm_upgraded`
- `log`

Controller event frames use:

```text
id: <millisecond timestamp>
event: <event name>
data: {"data":<payload>,"timestamp":"<ISO timestamp>"}

```

SSE streams send `: keepalive` comment frames. The event manager uses sliding capacity 100 channels and creates log channels as `logs:<sessionId>`.

OpenAI, Responses, Anthropic, and provider streams retain their upstream protocol-specific event framing. They are not converted into controller event frames.

### Controller environment

Core configuration:

- `LOCAL_STUDIO_CONTROLLER_MODE`
- `LOCAL_STUDIO_HOST`
- `LOCAL_STUDIO_PORT`
- `LOCAL_STUDIO_API_KEY`
- `LOCAL_STUDIO_ALLOW_UNAUTHENTICATED`
- `LOCAL_STUDIO_ALLOWED_HOSTS`
- `LOCAL_STUDIO_CORS_ORIGINS`
- `LOCAL_STUDIO_INFERENCE_HOST`
- `LOCAL_STUDIO_INFERENCE_PORT`
- `LOCAL_STUDIO_DATA_DIR`
- `LOCAL_STUDIO_DB_PATH`
- `LOCAL_STUDIO_MODELS_DIR`
- `LOCAL_STUDIO_STRICT_OPENAI_MODELS`
- `LOCAL_STUDIO_DISABLE_METRICS`
- `LOCAL_STUDIO_VERSION`

Runtime selection and discovery:

- `LOCAL_STUDIO_RUNTIME_BIN`
- `LOCAL_STUDIO_RUNTIME_PYTHON`
- `LOCAL_STUDIO_RUNTIME_PYTHONS`
- `LOCAL_STUDIO_RUNTIME_SKIP_SYSTEM`
- `LOCAL_STUDIO_RUNTIME_SKIP_DOCKER`
- `LOCAL_STUDIO_VLLM_PYTHONS`
- `LOCAL_STUDIO_SGLANG_PYTHON`
- `LOCAL_STUDIO_SGLANG_PYTHONS`
- `LOCAL_STUDIO_LLAMA_BIN`
- `LOCAL_STUDIO_MLX_PYTHON`
- `LOCAL_STUDIO_MLX_PYTHONS`

Runtime installation and upgrade:

- `LOCAL_STUDIO_VLLM_UPGRADE_CMD`
- `LOCAL_STUDIO_VLLM_UPGRADE_VERSION`
- `LOCAL_STUDIO_SGLANG_UPGRADE_CMD`
- `LOCAL_STUDIO_LLAMACPP_UPGRADE_CMD`
- `LOCAL_STUDIO_CUDA_UPGRADE_CMD`
- `LOCAL_STUDIO_ROCM_UPGRADE_CMD`

Compute, model, and hardware behavior:

- `LOCAL_STUDIO_ALLOW_CUSTOM_LAUNCH_COMMAND`
- `LOCAL_STUDIO_DEFAULT_TRUST_REMOTE_CODE`
- `LOCAL_STUDIO_READY_TIMEOUT_MS`
- `LOCAL_STUDIO_LAUNCH_NONCE`
- `LOCAL_STUDIO_GPU_SMI_TOOL`
- `LOCAL_STUDIO_ROCM_VERSION_FILE`
- `LOCAL_STUDIO_HF_TOKEN`

Logging:

- `LOCAL_STUDIO_LOG_LEVEL`
- `LOCAL_STUDIO_LOG_RETENTION_DAYS`
- `LOCAL_STUDIO_LOG_MAX_FILES`
- `LOCAL_STUDIO_LOG_MAX_TOTAL_BYTES`

Installer-only configuration:

- `LOCAL_STUDIO_DIR`
- `LOCAL_STUDIO_REPO`

The installer emits this exact completion prefix and JSON result:

```text
LOCAL_STUDIO_CONTROLLER {"url":"http://<host>:<port>","api_key":"<key>"}
```

### SQLite compatibility

The controller opens the configured database with `PRAGMA busy_timeout = 5000` and attempts mode `0600` on the database file.

Tables that must remain readable and rollback-safe:

- `controller_settings`
- `controller_requests`
- `controller_function_calls`
- `recipes`
- `model_downloads`
- `peak_metrics`
- `peak_metric_sessions`
- `lifetime_metrics`
- `inference_requests`
- `inference_usage_metadata`
- `rigs`
- `rig_node_credentials`
- `federated_session_metadata`

Important compatibility details:

- `recipes` may contain a legacy `json` payload column instead of `data`; Zig must detect both.
- `inference_requests` is incrementally migrated with `worker_id`, `event_id`, `occurred_at`, `origin_controller_id`, and `synced_at` columns.
- Missing inference event IDs are populated using lowercase random hex values.
- `inference_usage_metadata` stores the persistent `origin_controller_id`.
- `lifetime_metrics` initializes known counters without replacing unknown keys.
- JSON payload columns must remain opaque enough to preserve unknown fields.
- The Head credential table currently stores Worker API keys as plaintext. Encryption is a separate security decision and must not be mixed into compatibility work.

### Filesystem compatibility

Persistent files and directories:

- `<data_dir>/controller.db`
- `<data_dir>/studio-settings.json`
- `<data_dir>/instances/*.json`
- `<data_dir>/instances/logs/*.log`
- `<data_dir>/controller.log` and retained controller log files
- provider credential files already created under the data directory
- managed runtime environments and selected target records under the current data layout
- model directories under `LOCAL_STUDIO_MODELS_DIR`
- resumable download `.part` files in model target directories

`studio-settings.json` is written to a process-specific temporary path and renamed atomically. Its known fields are `models_dir`, `providers`, and `selected_runtime_target_ids`. Unknown fields must survive updates.

Instance records contain:

- `name`
- `nodeId`
- `engine`
- `recipeId`
- `runtime`
- `ref`
- `port`
- `devices`
- `nonce`
- `startedAt`
- `readyDeadlineAt`

Handle references may be `process`, `docker`, `docker-pending`, `remote`, or `pinned`. Record writes use exclusive temporary creation, file sync, and rename. Directory mode is `0700`; record mode is `0600` where supported.

### Process ownership compatibility

- Reservations are persisted before spawn.
- Instance records are the authoritative device and port leases.
- Placement uses an exclusive `placement.lock` file containing the holder PID.
- A placement lock is stale only when its holder PID is no longer alive.
- Placement lock polling is 25 ms with a 5 second timeout.
- Exact inference-port reservations fail if a record owns the port or bind probes show it unavailable.
- Port probes cover loopback and wildcard bindings.
- Process ownership requires PID, process group, session, start token, and launch nonce agreement.
- Linux identity reads `/proc/<pid>/stat` and `/proc/<pid>/environ`.
- Other POSIX identity reads `ps` output and the process environment.
- Docker ownership includes daemon identity, executable identity, container identity, and nonce.
- Stop uses TERM, a bounded grace period, and KILL.
- Process-group signaling must not target an unrelated group after PID reuse.
- The supervisor is the only reaper. Removing a dead instance record releases its devices and port.
- Raw engine logs remain on disk. HTTP, SSE, and launch-failure log tails are redacted at serialization boundaries.

## Current behavior that must be frozen before correction

1. Chat Completions has a dedicated federation route and least-active Worker selection.
2. Responses is classified as a Head path by the prefix allowlist but is implemented by the general Responses proxy rather than the federation route.
3. Anthropic Messages is not a Head path and therefore requires the management Worker header on Head.
4. `/v1/models/:modelId` is classified as a Head path because the current allowlist prefix-matches `/v1/models`, although only aggregate `/v1/models` has a dedicated federation implementation.
5. `/studio/provider-models` does not match `/studio/providers` and is proxied to a selected Worker, while `/studio/model-providers` and its generic login routes are Head-owned.
6. Unknown Head paths currently enter the selected-Worker proxy before the local not-found handler.
7. Federation retry is implemented specifically around the current Chat route rather than a shared inference-router commitment boundary.
8. The federation document says Worker keys are database-protected while the current table stores plaintext.

Each correction needs an explicit compatibility ledger update and live frontend acceptance evidence.

## Approved Zig ownership decisions

- `GET /studio/rigs` is `shared`. Head and Standalone use it for the local rig view, and Worker must serve it so Head hardware probes can resolve the Worker's detected local node. Rig mutations remain Head-owned and locally available in Standalone.
- Head `GET /studio/workers` preserves the existing payload and plaintext credential-table compatibility while enforcing credential non-disclosure, bounded probe concurrency, per-request deadlines, and bounded response bodies in Zig.
- Head selected-Worker forwarding uses the generated `proxied` ownership set, strips client credentials, attaches the stored Worker credential and federation-hop marker, replaces any Worker-supplied target header, and preserves streaming response commitment.
- Head `GET /v1/models` keeps the first healthy Worker's opaque model document, merges duplicate `active` with logical OR, uses the largest nonzero `max_model_len`, sorts by model ID, and excludes unhealthy Workers.
- Head Chat Completions buffers one bounded replayable body, chooses the least-active healthy Worker with name-based tie-breaking, releases active counts after downstream completion or failure, and retries one different Worker only when no response bytes were committed.
