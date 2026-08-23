const std = @import("std");
const config_module = @import("config.zig");
const shutdown = @import("shutdown.zig");
const reverse_proxy = @import("reverse_proxy.zig");
const route_registry = @import("route_registry.zig");
const rig_service = @import("services/rigs.zig");
const worker_service = @import("services/workers.zig");
const model_service = @import("services/models.zig");
const tokenization_service = @import("services/tokenization.zig");
const recipe_service = @import("services/recipes.zig");
const lifecycle = @import("services/lifecycle.zig");
const telemetry = @import("services/telemetry.zig");
const system_service = @import("services/system.zig");
const runtime_info = @import("services/runtime_info.zig");
const metrics = @import("services/metrics.zig");
const logs = @import("services/logs.zig");
const studio_settings = @import("services/studio_settings.zig");
const storage_service = @import("services/storage.zig");
const studio_operations = @import("services/studio_operations.zig");
const model_files = @import("services/model_files.zig");
const model_index = @import("services/model_index.zig");
const studio_models = @import("services/studio_models.zig");
const runtime_routes = @import("services/runtime_routes.zig");
const vram_calculator = @import("services/vram_calculator.zig");
const benchmark_service = @import("services/benchmark.zig");
const runtime_jobs_service = @import("services/runtime_jobs.zig");
const huggingface_models = @import("services/huggingface_models.zig");
const download_manager = @import("services/download_manager.zig");
const provider_service = @import("services/providers.zig");
const provider_catalog = @import("services/provider_catalog.zig");
const provider_routing = @import("services/provider_routing.zig");
const request_auth = @import("services/request_auth.zig");
const compute_plan = @import("services/compute_plan.zig");
const compute_lifecycle = @import("services/compute_lifecycle.zig");
const recipes = @import("repository/recipes.zig");
const peak_metrics = @import("repository/peak_metrics.zig");
const downloads = @import("repository/downloads.zig");
const sqlite = @import("repository/sqlite.zig");
const system_info = @import("platform/system_info.zig");
const topology = @import("topology.zig");

const Config = config_module.Config;
const Mode = config_module.Mode;
const Io = std.Io;
const net = Io.net;
const http = std.http;
const max_connection_tasks = 256;
const max_chat_request_bytes = 16 * 1024 * 1024;
const max_settings_request_bytes = 64 * 1024;

const ConnectionLimiter = struct {
    active: std.atomic.Value(usize) = .init(0),

    fn acquire(limiter: *ConnectionLimiter) bool {
        const previous = limiter.active.fetchAdd(1, .acq_rel);
        if (previous < max_connection_tasks) return true;
        _ = limiter.active.fetchSub(1, .acq_rel);
        return false;
    }

    fn release(limiter: *ConnectionLimiter) void {
        _ = limiter.active.fetchSub(1, .acq_rel);
    }
};

pub const HttpServer = struct {
    allocator: std.mem.Allocator,
    io: Io,
    config: Config,
    listener: net.Server,
    client: http.Client,
    studio: studio_settings.State,
    model_index_cache: model_index.Cache,
    runtime_jobs: runtime_jobs_service.State,
    downloads: download_manager.State,
    compute: compute_lifecycle.Manager,
    connection_limiter: ConnectionLimiter = .{},

    pub fn init(allocator: std.mem.Allocator, io: Io, config: Config) !HttpServer {
        const address = try net.IpAddress.parse(config.host, config.port);
        var studio = try studio_settings.State.init(allocator, config.models_dir);
        errdefer studio.deinit();
        var compute = try compute_lifecycle.Manager.init(allocator, io, config.data_dir);
        errdefer compute.deinit();
        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .listener = try address.listen(io, .{ .reuse_address = true }),
            .client = .{ .allocator = allocator, .io = io },
            .studio = studio,
            .model_index_cache = model_index.Cache.init(allocator, io),
            .runtime_jobs = runtime_jobs_service.State.init(allocator, io),
            .downloads = download_manager.State.init(allocator, io),
            .compute = compute,
        };
    }

    pub fn deinit(server: *HttpServer) void {
        server.listener.deinit(server.io);
        server.compute.deinit();
        server.downloads.deinit();
        server.client.deinit();
        server.studio.deinit();
        server.model_index_cache.deinit();
        server.runtime_jobs.deinit();
    }

    pub fn run(server: *HttpServer, database: *sqlite.Database, recipe_column: recipes.PayloadColumn, system: *const system_info.Snapshot, worker_pool: *worker_service.Pool, supervisor: *lifecycle.Supervisor, runtime_cache: *runtime_info.Cache) !void {
        var group: Io.Group = .init;
        defer group.cancel(server.io);
        if (server.config.mode != .head) try group.concurrent(server.io, runComputeSupervisor, .{&server.compute});
        while (!shutdown.isRequested()) {
            var stream = server.listener.accept(server.io) catch |failure| {
                if (shutdown.isRequested()) return;
                return failure;
            };
            if (!server.connection_limiter.acquire()) {
                rejectOverloadedConnection(server.io, &stream);
                continue;
            }
            group.concurrent(server.io, serveConnection, .{ server.allocator, server.io, server.config.mode, &server.config, &server.studio, &server.model_index_cache, &server.runtime_jobs, &server.downloads, &server.compute, &server.client, database, recipe_column, server.config.llm_instance_path, server.config.inference_port, server.config.inference_origin, server.config.default_trust_remote_code, server.config.environment, system, worker_pool, supervisor, runtime_cache, server.config.spike_upstream, server.config.spike_fallback_upstream, &server.connection_limiter, stream }) catch {
                server.connection_limiter.release();
                stream.close(server.io);
            };
        }
    }
};

fn runComputeSupervisor(manager: *compute_lifecycle.Manager) Io.Cancelable!void {
    return manager.run();
}

fn serveConnection(allocator: std.mem.Allocator, io: Io, mode: Mode, configuration: *const Config, studio: *studio_settings.State, model_index_cache: *model_index.Cache, runtime_jobs: *runtime_jobs_service.State, download_state: *download_manager.State, compute: *compute_lifecycle.Manager, client: *http.Client, database: *sqlite.Database, recipe_column: recipes.PayloadColumn, llm_instance_path: []const u8, inference_port: u16, inference_origin: []const u8, default_trust_remote_code: bool, environment: *const std.process.Environ.Map, system: *const system_info.Snapshot, worker_pool: *worker_service.Pool, supervisor: *lifecycle.Supervisor, runtime_cache: *runtime_info.Cache, spike_upstream: ?[]const u8, spike_fallback_upstream: ?[]const u8, connection_limiter: *ConnectionLimiter, stream: net.Stream) void {
    defer {
        connection_limiter.release();
        var connection = stream;
        connection.close(io);
    }

    var send_buffer: [16 * 1024]u8 = undefined;
    var receive_buffer: [16 * 1024]u8 = undefined;
    var connection_reader = stream.reader(io, &receive_buffer);
    var connection_writer = stream.writer(io, &send_buffer);
    var server: http.Server = .init(&connection_reader.interface, &connection_writer.interface);

    while (true) {
        var request = server.receiveHead() catch |failure| {
            switch (failure) {
                error.HttpHeadersOversize => writeProtocolError(&connection_writer.interface, "431 Request Header Fields Too Large"),
                error.HttpHeadersInvalid => writeProtocolError(&connection_writer.interface, "400 Bad Request"),
                else => {},
            }
            return;
        };
        const keep_connection = serveRequest(allocator, io, mode, configuration, studio, model_index_cache, runtime_jobs, download_state, compute, client, database, recipe_column, llm_instance_path, inference_port, inference_origin, default_trust_remote_code, environment, system, worker_pool, supervisor, runtime_cache, spike_upstream, spike_fallback_upstream, &request) catch return;
        if (!keep_connection) return;
    }
}

fn writeProtocolError(writer: *Io.Writer, status: []const u8) void {
    writer.print("HTTP/1.1 {s}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n", .{status}) catch return;
    writer.flush() catch return;
}

fn rejectOverloadedConnection(io: Io, stream: *net.Stream) void {
    defer stream.close(io);
    var buffer: [256]u8 = undefined;
    var writer = stream.writer(io, &buffer);
    writeProtocolError(&writer.interface, "503 Service Unavailable");
}

fn serveRequest(allocator: std.mem.Allocator, io: Io, mode: Mode, configuration: *const Config, studio: *studio_settings.State, model_index_cache: *model_index.Cache, runtime_jobs: *runtime_jobs_service.State, download_state: *download_manager.State, compute: *compute_lifecycle.Manager, client: *http.Client, database: *sqlite.Database, recipe_column: recipes.PayloadColumn, llm_instance_path: []const u8, inference_port: u16, inference_origin: []const u8, default_trust_remote_code: bool, environment: *const std.process.Environ.Map, system: *const system_info.Snapshot, worker_pool: *worker_service.Pool, supervisor: *lifecycle.Supervisor, runtime_cache: *runtime_info.Cache, spike_upstream: ?[]const u8, spike_fallback_upstream: ?[]const u8, request: *http.Server.Request) !bool {
    if (request.head.method.requestHasBody() and request.head.transfer_encoding == .none and request.head.content_length == null) request.head.keep_alive = false;
    const route = route_registry.find(request.head.method, request.head.target) orelse {
        try request.respond("{\"detail\":\"Not Found\"}", .{
            .status = .not_found,
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        });
        return request.head.keep_alive;
    };

    if (!std.mem.eql(u8, route.path, "/health") and !request_auth.authorized(request, configuration.api_key)) {
        try request.respond("{\"detail\":\"Unauthorized\"}", .{
            .status = .unauthorized,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
                .{ .name = "WWW-Authenticate", .value = "Bearer realm=\"local-studio-controller\"" },
            },
        });
        return request.head.keep_alive;
    }

    switch (topology.routeDisposition(mode, route)) {
        .local => {},
        .proxy => {
            return try serveWorkerProxy(allocator, io, client, database, request);
        },
        .reject => {
            try request.respond("{\"detail\":\"Not Found\"}", .{
                .status = .not_found,
                .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
            });
            return request.head.keep_alive;
        },
    }

    if (std.mem.eql(u8, route.path, "/health")) {
        try request.respond("{\"status\":\"ok\"}", .{
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        });
        return request.head.keep_alive;
    }
    if (std.mem.eql(u8, route.path, "/studio/rigs")) {
        const response = try rig_service.payload(allocator, io, mode, system, database);
        defer allocator.free(response);
        try request.respond(response, .{
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        });
        return request.head.keep_alive;
    }
    if (std.mem.eql(u8, route.path, "/studio/workers")) {
        const response = try worker_service.payload(allocator, io, mode, client, database, worker_pool);
        defer allocator.free(response);
        try request.respond(response, .{
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        });
        return request.head.keep_alive;
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/studio/settings") and request.head.method == .GET) {
        const response = try studio_settings.payload(allocator, io, configuration, studio, database);
        defer allocator.free(response);
        try request.respond(response, .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return request.head.keep_alive;
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/studio/settings") and request.head.method == .POST) {
        return serveStudioSettingsUpdate(allocator, io, configuration, studio, database, request);
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/studio/storage")) {
        const models_dir = try studio.modelsDirectory(allocator, io);
        defer allocator.free(models_dir);
        const response = try storage_service.payload(allocator, io, models_dir);
        defer allocator.free(response);
        try request.respond(response, .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return request.head.keep_alive;
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/studio/diagnostics")) {
        const models_dir = try studio.modelsDirectory(allocator, io);
        defer allocator.free(models_dir);
        const response = try studio_operations.diagnosticsPayload(allocator, io, configuration, models_dir, system, runtime_cache);
        defer allocator.free(response);
        try request.respond(response, .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return request.head.keep_alive;
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/studio/presets")) {
        const response = try studio_operations.presetsPayload(allocator, io, system);
        defer allocator.free(response);
        try request.respond(response, .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return request.head.keep_alive;
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/vram-calculator")) {
        return serveVramCalculator(allocator, io, configuration, system, request);
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/peak-metrics")) {
        const model_id = try queryParameter(allocator, request.head.target, "model_id");
        defer if (model_id) |value| allocator.free(value);
        const response = response: {
            try database.lock(io);
            defer database.unlock(io);
            if (model_id) |value| {
                if (value.len > 0) break :response (try peak_metrics.onePayload(allocator, database, value)) orelse try allocator.dupe(u8, "{\"error\":\"No metrics for this model\"}");
            }
            break :response try peak_metrics.allPayload(allocator, database);
        };
        defer allocator.free(response);
        try request.respond(response, .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return request.head.keep_alive;
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/benchmark")) {
        const prompt_value = try queryParameter(allocator, request.head.target, "prompt_tokens");
        defer if (prompt_value) |value| allocator.free(value);
        const prompt_tokens = if (prompt_value) |value| std.fmt.parseInt(usize, value, 10) catch 0 else 1000;
        if (prompt_tokens < 1 or prompt_tokens > 100_000) {
            try request.respond("{\"detail\":\"Invalid benchmark query\"}", .{ .status = .bad_request, .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
            return request.head.keep_alive;
        }
        const response = benchmark_service.payload(allocator, io, client, database, recipe_column, llm_instance_path, inference_origin, default_trust_remote_code, prompt_tokens) catch |failure| {
            const detail: []const u8 = switch (failure) {
                error.BenchmarkRequestFailed => "Benchmark request failed",
                error.InvalidBenchmarkResponse => "Invalid benchmark response",
                else => return failure,
            };
            var output: Io.Writer.Allocating = .init(allocator);
            defer output.deinit();
            try output.writer.writeAll("{\"detail\":");
            try std.json.Stringify.value(detail, .{}, &output.writer);
            try output.writer.writeByte('}');
            try request.respond(output.writer.buffered(), .{ .status = .service_unavailable, .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
            return request.head.keep_alive;
        };
        defer allocator.free(response);
        try request.respond(response, .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return request.head.keep_alive;
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/studio/models/delete")) {
        return serveStudioModelMutation(allocator, io, studio, request, .delete);
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/studio/models/move")) {
        return serveStudioModelMutation(allocator, io, studio, request, .move);
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/studio/model-index")) {
        return serveModelIndex(allocator, configuration, model_index_cache, request);
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/v1/studio/models")) {
        const models_dir = try studio.modelsDirectory(allocator, io);
        defer allocator.free(models_dir);
        const response = try studio_models.payload(allocator, io, database, recipe_column, models_dir, environment);
        defer allocator.free(response);
        try request.respond(response, .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return request.head.keep_alive;
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/v1/huggingface/models")) {
        const search_value = try queryParameter(allocator, request.head.target, "search");
        defer if (search_value) |value| allocator.free(value);
        const filter_value = try queryParameter(allocator, request.head.target, "filter");
        defer if (filter_value) |value| allocator.free(value);
        const sort_value = try queryParameter(allocator, request.head.target, "sort");
        defer if (sort_value) |value| allocator.free(value);
        const search = if (search_value) |value| trimmedOptional(value) else null;
        const filter = if (filter_value) |value| if (value.len > 0) value else null else null;
        const sort = if (sort_value) |value| trimmedOptional(value) else null;
        const limit: usize = @intCast(@min(@max(queryUnsigned(request.head.target, "limit") orelse 50, 1), 100));
        const raw_offset = queryUnsigned(request.head.target, "offset") orelse 0;
        const offset = std.math.cast(usize, raw_offset) orelse std.math.maxInt(usize);
        var result = huggingface_models.payload(allocator, io, client, environment, search, filter, sort, limit, offset) catch |failure| {
            var output: Io.Writer.Allocating = .init(allocator);
            defer output.deinit();
            try output.writer.writeAll("{\"detail\":");
            const detail = try std.fmt.allocPrint(allocator, "Failed to reach HuggingFace API: {t}", .{failure});
            defer allocator.free(detail);
            try std.json.Stringify.value(detail, .{}, &output.writer);
            try output.writer.writeByte('}');
            try request.respond(output.writer.buffered(), .{ .status = .service_unavailable, .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
            return request.head.keep_alive;
        };
        defer result.deinit();
        try request.respond(result.body, .{ .status = result.status, .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return request.head.keep_alive;
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/studio/downloads") and request.head.method == .GET) {
        const response = response: {
            try database.lock(io);
            defer database.unlock(io);
            break :response try downloads.listPayload(allocator, database);
        };
        defer allocator.free(response);
        try request.respond(response, .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return request.head.keep_alive;
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/studio/downloads") and request.head.method == .POST) {
        return serveDownloadStart(allocator, io, configuration, studio, download_state, client, database, request);
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/studio/downloads/:downloadId") and request.head.method == .GET) {
        const download_id = try pathParameter(allocator, request.head.target, "/studio/downloads/");
        defer allocator.free(download_id);
        const response = response: {
            try database.lock(io);
            defer database.unlock(io);
            break :response try downloads.getPayload(allocator, database, download_id);
        };
        const download = response orelse {
            try request.respond("{\"detail\":\"Download not found\"}", .{ .status = .not_found, .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
            return request.head.keep_alive;
        };
        defer allocator.free(download);
        var output: Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        try output.writer.writeAll("{\"download\":");
        try output.writer.writeAll(download);
        try output.writer.writeByte('}');
        try request.respond(output.writer.buffered(), .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return request.head.keep_alive;
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/studio/downloads/:downloadId/pause")) {
        return serveDownloadControl(allocator, configuration, download_state, client, database, request, .pause);
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/studio/downloads/:downloadId/resume")) {
        return serveDownloadControl(allocator, configuration, download_state, client, database, request, .@"resume");
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/studio/downloads/:downloadId/cancel")) {
        return serveDownloadControl(allocator, configuration, download_state, client, database, request, .cancel);
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/studio/provider-models") and request.head.method == .GET) {
        var snapshot = try provider_service.loadSnapshot(allocator, io, studio, configuration.data_dir);
        defer snapshot.deinit();
        const response = try provider_catalog.payload(allocator, io, client, snapshot.providers);
        defer allocator.free(response);
        try request.respond(response, .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return request.head.keep_alive;
    }
    if (std.mem.eql(u8, route.path, "/studio/providers") and request.head.method == .GET) {
        const response = try provider_service.listPayload(allocator, io, studio, configuration.data_dir);
        defer allocator.free(response);
        try request.respond(response, .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return request.head.keep_alive;
    }
    if (std.mem.eql(u8, route.path, "/studio/providers") and request.head.method == .POST) {
        const document = try readBoundedJsonBody(allocator, request) orelse return false;
        defer allocator.free(document);
        const response = provider_service.createPayload(allocator, io, studio, configuration.data_dir, document) catch |failure| return respondProviderFailure(request, failure, null);
        defer allocator.free(response);
        try request.respond(response, .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return request.head.keep_alive;
    }
    if (std.mem.eql(u8, route.path, "/studio/providers/:id") and (request.head.method == .PUT or request.head.method == .DELETE)) {
        const provider_id = try pathParameter(allocator, request.head.target, "/studio/providers/");
        defer allocator.free(provider_id);
        const response = if (request.head.method == .PUT) response: {
            const document = try readBoundedJsonBody(allocator, request) orelse return false;
            defer allocator.free(document);
            break :response provider_service.updatePayload(allocator, io, studio, configuration.data_dir, provider_id, document) catch |failure| return respondProviderFailure(request, failure, provider_id);
        } else provider_service.deletePayload(allocator, io, studio, configuration.data_dir, provider_id) catch |failure| return respondProviderFailure(request, failure, provider_id);
        defer allocator.free(response);
        try request.respond(response, .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return request.head.keep_alive;
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/runtime/vllm")) {
        return serveRuntimeBackend(allocator, configuration, system, runtime_cache, .vllm, request);
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/runtime/sglang")) {
        return serveRuntimeBackend(allocator, configuration, system, runtime_cache, .sglang, request);
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/runtime/llamacpp")) {
        return serveRuntimeBackend(allocator, configuration, system, runtime_cache, .llamacpp, request);
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/runtime/mlx")) {
        return serveRuntimeBackend(allocator, configuration, system, runtime_cache, .mlx, request);
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/runtime/cuda")) {
        const response = try runtime_routes.cudaPayload(allocator, configuration, system, runtime_cache);
        defer allocator.free(response);
        try request.respond(response, .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return request.head.keep_alive;
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/runtime/rocm")) {
        const response = try runtime_routes.rocmPayload(allocator, configuration, system, runtime_cache);
        defer allocator.free(response);
        try request.respond(response, .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return request.head.keep_alive;
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/runtime/vllm/config")) {
        return serveRuntimeConfigHelp(allocator, io, configuration, .vllm, request);
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/runtime/llamacpp/config")) {
        return serveRuntimeConfigHelp(allocator, io, configuration, .llamacpp, request);
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/runtime/targets") and request.head.method == .GET) {
        const response = try runtime_routes.targetsPayload(allocator, io, configuration, system, runtime_cache, supervisor);
        defer allocator.free(response);
        try request.respond(response, .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return request.head.keep_alive;
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/runtime/targets/:targetId/select")) {
        const target_id = try pathParameterBetween(allocator, request.head.target, "/runtime/targets/", "/select");
        defer allocator.free(target_id);
        try studio.lockSettings(io);
        defer studio.unlockSettings(io);
        const response = try runtime_routes.selectTargetPayload(allocator, io, configuration, system, runtime_cache, supervisor, target_id) orelse {
            try request.respond("{\"detail\":\"Runtime target not found\"}", .{ .status = .not_found, .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
            return request.head.keep_alive;
        };
        defer allocator.free(response);
        try request.respond(response, .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return request.head.keep_alive;
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/runtime/jobs") and request.head.method == .GET) {
        const response = try runtime_jobs.listPayload();
        defer allocator.free(response);
        try request.respond(response, .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return request.head.keep_alive;
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/runtime/jobs") and request.head.method == .POST) {
        return serveRuntimeJobCreate(allocator, configuration, runtime_jobs, runtime_cache, request, null, false);
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/runtime/jobs/:jobId") and request.head.method == .GET) {
        const job_id = try pathParameter(allocator, request.head.target, "/runtime/jobs/");
        defer allocator.free(job_id);
        const response = try runtime_jobs.onePayload(job_id) orelse {
            try request.respond("{\"detail\":\"Runtime job not found\"}", .{ .status = .not_found, .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
            return request.head.keep_alive;
        };
        defer allocator.free(response);
        try request.respond(response, .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return request.head.keep_alive;
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/runtime/jobs/:jobId/cancel")) {
        const job_id = try pathParameterBetween(allocator, request.head.target, "/runtime/jobs/", "/cancel");
        defer allocator.free(job_id);
        const response = try runtime_jobs.cancelPayload(job_id) orelse {
            try request.respond("{\"detail\":\"Runtime job not found\"}", .{ .status = .not_found, .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
            return request.head.keep_alive;
        };
        defer allocator.free(response);
        try request.respond(response, .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return request.head.keep_alive;
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/runtime/:backend/upgrade")) {
        const backend = try pathParameterBetween(allocator, request.head.target, "/runtime/", "/upgrade");
        defer allocator.free(backend);
        if (!runtimeJobBackend(backend)) {
            try request.respond("{\"detail\":\"Unknown runtime backend\"}", .{ .status = .not_found, .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
            return request.head.keep_alive;
        }
        return serveRuntimeJobCreate(allocator, configuration, runtime_jobs, runtime_cache, request, backend, true);
    }
    if (mode == .head and std.mem.eql(u8, route.path, "/v1/models")) {
        const worker_response = try worker_service.modelCatalogPayload(allocator, io, client, database);
        defer allocator.free(worker_response);
        var snapshot = try provider_service.loadSnapshot(allocator, io, studio, configuration.data_dir);
        defer snapshot.deinit();
        const provider_response = try provider_catalog.payload(allocator, io, client, snapshot.providers);
        defer allocator.free(provider_response);
        const response = try provider_routing.mergedModelCatalog(allocator, worker_response, provider_response);
        defer allocator.free(response);
        try request.respond(response, .{
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        });
        return request.head.keep_alive;
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/v1/models")) {
        const response = try model_service.localCatalogPayload(allocator, io, database, recipe_column, llm_instance_path);
        defer allocator.free(response);
        try request.respond(response, .{
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        });
        return request.head.keep_alive;
    }
    if (mode == .head and std.mem.eql(u8, route.path, "/v1/chat/completions")) {
        return try serveHeadInference(allocator, io, configuration, studio, client, database, worker_pool, request);
    }
    if (mode == .head and std.mem.eql(u8, route.path, "/v1/responses")) {
        return try serveHeadInference(allocator, io, configuration, studio, client, database, worker_pool, request);
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/v1/chat/completions")) {
        return try serveLocalChat(allocator, io, configuration, studio, client, database, recipe_column, llm_instance_path, request, inference_origin);
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/v1/responses")) {
        return try serveLocalPassthrough(allocator, io, configuration, studio, client, database, recipe_column, llm_instance_path, request, inference_origin, .responses);
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/v1/messages")) {
        return try serveLocalPassthrough(allocator, io, configuration, studio, client, database, recipe_column, llm_instance_path, request, inference_origin, .messages);
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/v1/count-tokens")) {
        return try serveTokenization(allocator, io, client, database, recipe_column, llm_instance_path, request, inference_origin, .count);
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/v1/tokenize-chat-completions")) {
        return try serveTokenization(allocator, io, client, database, recipe_column, llm_instance_path, request, inference_origin, .chat);
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/launch/:recipeId")) {
        const recipe_id = try pathParameter(allocator, request.head.target, "/launch/");
        defer allocator.free(recipe_id);
        supervisor.launch(client, database, recipe_column, recipe_id, configuration) catch |failure| {
            return try respondLifecycleFailure(request, failure);
        };
        try request.respond("{\"success\":true,\"message\":\"Launch started\"}", .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return request.head.keep_alive;
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/launch/:recipeId/cancel")) {
        const recipe_id = try pathParameterBetween(allocator, request.head.target, "/launch/", "/cancel");
        defer allocator.free(recipe_id);
        if (!(try supervisor.cancelLaunch())) {
            var output: Io.Writer.Allocating = .init(allocator);
            defer output.deinit();
            try output.writer.writeAll("{\"detail\":");
            const detail = try std.fmt.allocPrint(allocator, "No launch in progress for {s}", .{recipe_id});
            defer allocator.free(detail);
            try std.json.Stringify.value(detail, .{}, &output.writer);
            try output.writer.writeByte('}');
            try request.respond(output.writer.buffered(), .{ .status = .not_found, .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
            return request.head.keep_alive;
        }
        var output: Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        try output.writer.writeAll("{\"success\":true,\"message\":");
        const message = try std.fmt.allocPrint(allocator, "Launch of {s} cancelled", .{recipe_id});
        defer allocator.free(message);
        try std.json.Stringify.value(message, .{}, &output.writer);
        try output.writer.writeByte('}');
        try request.respond(output.writer.buffered(), .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return request.head.keep_alive;
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/evict")) {
        _ = supervisor.evict() catch |failure| {
            return try respondLifecycleFailure(request, failure);
        };
        try request.respond("{\"success\":true,\"evicted_pid\":null}", .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return request.head.keep_alive;
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/wait-ready")) {
        const timeout = queryUnsigned(request.head.target, "timeout") orelse 300;
        const started = Io.Clock.awake.now(io);
        const ready = try supervisor.waitReady(client, @min(timeout, 86_400));
        const elapsed = @max(started.durationTo(Io.Clock.awake.now(io)).toSeconds(), 0);
        var output: Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        if (ready) {
            try output.writer.print("{{\"ready\":true,\"elapsed\":{d}}}", .{elapsed});
        } else {
            try output.writer.print("{{\"ready\":false,\"elapsed\":{d},\"error\":\"Timeout waiting for backend\"}}", .{timeout});
        }
        try request.respond(output.writer.buffered(), .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return request.head.keep_alive;
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/status")) {
        const response = try supervisor.statusPayload(database, recipe_column, inference_port, default_trust_remote_code);
        defer allocator.free(response);
        try request.respond(response, .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return request.head.keep_alive;
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/gpus")) {
        const response = try telemetry.gpuPayload(allocator, io, system);
        defer allocator.free(response);
        try request.respond(response, .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return request.head.keep_alive;
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/config")) {
        const models_dir = try studio.modelsDirectory(allocator, io);
        defer allocator.free(models_dir);
        const response = try system_service.configPayload(allocator, io, configuration, models_dir, system, supervisor, runtime_cache);
        defer allocator.free(response);
        try request.respond(response, .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return request.head.keep_alive;
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/compat")) {
        const response = try system_service.compatibilityPayload(allocator, io, configuration, system, supervisor, runtime_cache);
        defer allocator.free(response);
        try request.respond(response, .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return request.head.keep_alive;
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/compute/engines")) {
        const response = try system_service.computeEnginesPayload(allocator, io, configuration, system, runtime_cache);
        defer allocator.free(response);
        try request.respond(response, .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return request.head.keep_alive;
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/compute/devices")) {
        const response = try telemetry.devicePayload(allocator, io, system);
        defer allocator.free(response);
        try request.respond(response, .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return request.head.keep_alive;
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/v1/metrics/vllm")) {
        const response = try metrics.payload(allocator, io, client, database, recipe_column, inference_port, default_trust_remote_code, system, supervisor);
        defer allocator.free(response);
        try request.respond(response, .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return request.head.keep_alive;
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/events")) {
        try serveControllerEvents(allocator, io, client, database, recipe_column, configuration, studio, default_trust_remote_code, system, supervisor, runtime_cache, request);
        return false;
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/logs") and request.head.method == .GET) {
        const response = try logs.listPayload(allocator, io, configuration, database, recipe_column, default_trust_remote_code, supervisor);
        defer allocator.free(response);
        try request.respond(response, .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return request.head.keep_alive;
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/logs/:sessionId") and request.head.method == .GET) {
        const session_id = try pathParameter(allocator, request.head.target, "/logs/");
        defer allocator.free(session_id);
        const limit_value = queryUnsigned(request.head.target, "limit") orelse 2000;
        if (limit_value == 0 or limit_value > 20_000) {
            try request.respond("{\"detail\":\"Invalid log limit\"}", .{ .status = .bad_request, .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
            return request.head.keep_alive;
        }
        const response = logs.tailPayload(allocator, io, configuration, session_id, @intCast(limit_value)) catch |failure| {
            if (failure == error.InvalidSessionId) {
                try request.respond("{\"detail\":\"Invalid log session id\"}", .{ .status = .bad_request, .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
                return request.head.keep_alive;
            }
            return failure;
        } orelse {
            try request.respond("{\"detail\":\"Log not found\"}", .{ .status = .not_found, .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
            return request.head.keep_alive;
        };
        defer allocator.free(response);
        try request.respond(response, .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return request.head.keep_alive;
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/logs/:sessionId") and request.head.method == .DELETE) {
        const session_id = try pathParameter(allocator, request.head.target, "/logs/");
        defer allocator.free(session_id);
        const deleted = logs.delete(io, allocator, configuration, session_id) catch |failure| switch (failure) {
            error.InvalidSessionId => {
                try request.respond("{\"detail\":\"Invalid log session id\"}", .{ .status = .bad_request, .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
                return request.head.keep_alive;
            },
            error.ControllerLogProtected => {
                try request.respond("{\"detail\":\"controller logs cannot be deleted via API\"}", .{ .status = .bad_request, .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
                return request.head.keep_alive;
            },
            else => return failure,
        };
        if (!deleted) {
            try request.respond("{\"detail\":\"Log not found\"}", .{ .status = .not_found, .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
            return request.head.keep_alive;
        }
        try request.respond("{\"success\":true}", .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return request.head.keep_alive;
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/logs/:sessionId/stream")) {
        const session_id = try pathParameterBetween(allocator, request.head.target, "/logs/", "/stream");
        defer allocator.free(session_id);
        const tail_value = queryUnsigned(request.head.target, "tail") orelse 2000;
        if (tail_value > 20_000) {
            try request.respond("{\"detail\":\"Invalid log tail\"}", .{ .status = .bad_request, .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
            return request.head.keep_alive;
        }
        const log_path = logs.resolveLogPath(allocator, io, configuration, session_id) catch |failure| {
            if (failure == error.InvalidSessionId) {
                try request.respond("{\"detail\":\"Invalid log session id\"}", .{ .status = .bad_request, .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
                return request.head.keep_alive;
            }
            return failure;
        } orelse {
            try request.respond("{\"detail\":\"Log not found\"}", .{ .status = .not_found, .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
            return request.head.keep_alive;
        };
        defer allocator.free(log_path);
        try serveLogStream(allocator, io, configuration, session_id, log_path, @intCast(tail_value), request);
        return false;
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/compute/instances") and request.head.method == .GET) {
        const response = try compute.instancesPayload(client);
        defer allocator.free(response);
        try request.respond(response, .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return request.head.keep_alive;
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/compute/launch") and request.head.method == .POST) {
        return serveComputeLaunch(allocator, configuration, system, compute, client, request);
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/compute/instances/:name/stop") and request.head.method == .POST) {
        const name = try pathParameterBetween(allocator, request.head.target, "/compute/instances/", "/stop");
        defer allocator.free(name);
        const stopped = if (std.mem.eql(u8, name, "llm")) stopped: {
            _ = try compute.cancelActive(name);
            break :stopped supervisor.stopNamed(name) catch |failure| return try respondLifecycleFailure(request, failure);
        } else try compute.stop(name);
        try request.respond(if (stopped) "{\"stopped\":true}" else "{\"stopped\":false}", .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return request.head.keep_alive;
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/compute/instances/:name/cancel") and request.head.method == .POST) {
        const name = try pathParameterBetween(allocator, request.head.target, "/compute/instances/", "/cancel");
        defer allocator.free(name);
        const cancelled = if (try compute.cancelActive(name)) true else if (std.mem.eql(u8, name, "llm")) try supervisor.cancelNamed(name) else try compute.cancel(name);
        try request.respond(if (cancelled) "{\"cancelled\":true}" else "{\"cancelled\":false}", .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return request.head.keep_alive;
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/recipes") and request.head.method == .GET) {
        const response = try recipe_service.listPayload(allocator, io, database, recipe_column, llm_instance_path, default_trust_remote_code);
        defer allocator.free(response);
        try request.respond(response, .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return request.head.keep_alive;
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/recipes/:recipeId") and request.head.method == .GET) {
        const recipe_id = try pathParameter(allocator, request.head.target, "/recipes/");
        defer allocator.free(recipe_id);
        const response = try recipe_service.detailPayload(allocator, io, database, recipe_column, recipe_id, default_trust_remote_code) orelse {
            try request.respond("{\"detail\":\"Recipe not found\"}", .{
                .status = .not_found,
                .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
            });
            return request.head.keep_alive;
        };
        defer allocator.free(response);
        try request.respond(response, .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return request.head.keep_alive;
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/recipes") and request.head.method == .POST) {
        return try saveRecipe(allocator, io, database, recipe_column, request, null, default_trust_remote_code);
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/recipes/:recipeId") and request.head.method == .PUT) {
        const recipe_id = try pathParameter(allocator, request.head.target, "/recipes/");
        defer allocator.free(recipe_id);
        return try saveRecipe(allocator, io, database, recipe_column, request, recipe_id, default_trust_remote_code);
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/recipes/:recipeId") and request.head.method == .DELETE) {
        const recipe_id = try pathParameter(allocator, request.head.target, "/recipes/");
        defer allocator.free(recipe_id);
        if (!(try recipe_service.delete(io, database, recipe_id))) {
            try request.respond("{\"detail\":\"Recipe not found\"}", .{
                .status = .not_found,
                .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
            });
            return request.head.keep_alive;
        }
        try request.respond("{\"success\":true}", .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return request.head.keep_alive;
    }
    if (std.mem.eql(u8, route.path, "/__zig-spike/proxy")) {
        const upstream = spike_upstream orelse {
            try request.respond("{\"detail\":\"Proxy spike upstream is not configured\"}", .{
                .status = .service_unavailable,
                .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
            });
            return request.head.keep_alive;
        };
        try reverse_proxy.serve(client, upstream, spike_fallback_upstream, request);
        return false;
    }

    if (std.mem.eql(u8, route.path, "/__zig-spike/sse")) {
        try serveSse(io, request);
        return false;
    }

    try request.respond("{\"detail\":\"Route is not implemented by the Zig migration slice\"}", .{
        .status = .not_implemented,
        .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
    });
    return request.head.keep_alive;
}

const DownloadControl = enum { pause, @"resume", cancel };

fn serveComputeLaunch(allocator: std.mem.Allocator, configuration: *const Config, system: *const system_info.Snapshot, compute: *compute_lifecycle.Manager, client: *http.Client, request: *http.Server.Request) !bool {
    const storage = try allocator.alloc(u8, max_settings_request_bytes);
    defer allocator.free(storage);
    var body_writer: Io.Writer = .fixed(storage);
    var request_buffer: [16 * 1024]u8 = undefined;
    const reader = try request.readerExpectContinue(&request_buffer);
    _ = reader.streamRemaining(&body_writer) catch {
        try request.respond("{\"detail\":\"unreadable launch request\"}", .{ .status = .bad_request, .keep_alive = false, .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return false;
    };
    var parsed = compute_plan.parse(allocator, body_writer.buffered()) catch |failure| {
        const detail: []const u8 = if (failure == error.ForbiddenEngineArgument) "invalid launch request: forbidden engine argument" else "invalid launch request";
        return respondDownloadError(request, .bad_request, detail);
    };
    defer parsed.deinit();
    const response = compute.launchPayload(client, configuration, system, &parsed) catch |failure| return respondComputeFailure(request, failure, &parsed);
    defer allocator.free(response);
    try request.respond(response, .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
    return request.head.keep_alive;
}

fn respondComputeFailure(request: *http.Server.Request, failure: anyerror, launch: *const compute_plan.Request) !bool {
    const status: http.Status = switch (failure) {
        error.UnsupportedEngine, error.DockerRuntimeNotImplemented => .unprocessable_entity,
        error.AlreadyRunning, error.NoCapacity => .conflict,
        error.LaunchCancelled => .bad_request,
        error.TooManyActiveLaunches => .service_unavailable,
        else => .service_unavailable,
    };
    var buffer: [4096]u8 = undefined;
    var output: Io.Writer = .fixed(&buffer);
    switch (failure) {
        error.UnsupportedEngine => try output.print("{s} cannot run here: unsupported on this host", .{launch.engine}),
        error.DockerRuntimeNotImplemented => try output.print("{s} cannot run here: runtime \"docker\" not available", .{launch.engine}),
        error.AlreadyRunning => if (launch.name.len <= 1024) try output.print("{s} is already running", .{launch.name}) else try output.writeAll("instance is already running"),
        error.NoCapacity => try output.print("needs {d} device(s); not enough free", .{launch.device_count}),
        error.LaunchCancelled => try output.writeAll("launch cancelled"),
        error.ReadinessTimeout => try output.writeAll("not healthy before the readiness deadline"),
        error.ProcessExitedEarly => try output.writeAll("process exited before becoming healthy"),
        error.TooManyActiveLaunches => try output.writeAll("too many active launches"),
        else => try output.writeAll(@errorName(failure)),
    }
    return respondDownloadError(request, status, output.buffered());
}

fn serveDownloadStart(allocator: std.mem.Allocator, io: Io, configuration: *const Config, studio: *studio_settings.State, state: *download_manager.State, client: *http.Client, database: *sqlite.Database, request: *http.Server.Request) !bool {
    const header_token = try capturedDownloadTokenHeader(allocator, request);
    defer if (header_token) |value| allocator.free(value);
    const document = try readBoundedJsonBody(allocator, request) orelse return false;
    defer allocator.free(document);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, document, .{}) catch return respondDownloadError(request, .bad_request, "Invalid JSON body");
    defer parsed.deinit();
    if (parsed.value != .object) return respondDownloadError(request, .bad_request, "Invalid JSON body");
    const object = parsed.value.object;
    const model_id = requiredDownloadString(object, "model_id") catch return respondDownloadError(request, .bad_request, "model_id is required");
    const revision = optionalDownloadString(object, "revision") catch return respondDownloadError(request, .bad_request, "Invalid revision");
    const destination = optionalDownloadString(object, "destination_dir") catch return respondDownloadError(request, .bad_request, "Invalid destination_dir");
    const body_token = optionalDownloadString(object, "hf_token") catch return respondDownloadError(request, .bad_request, "Invalid hf_token");
    const allow_patterns = downloadPatterns(allocator, object, "allow_patterns") catch return respondDownloadError(request, .bad_request, "Invalid allow_patterns");
    defer allocator.free(allow_patterns);
    const ignore_patterns = downloadPatterns(allocator, object, "ignore_patterns") catch return respondDownloadError(request, .bad_request, "Invalid ignore_patterns");
    defer allocator.free(ignore_patterns);
    const token = downloadToken(configuration.environment, body_token, header_token);
    const models_dir = try studio.modelsDirectory(allocator, io);
    defer allocator.free(models_dir);
    var result = state.startPayload(configuration, client, database, models_dir, .{
        .model_id = model_id,
        .revision = revision,
        .destination_dir = destination,
        .allow_patterns = allow_patterns,
        .ignore_patterns = ignore_patterns,
        .token = token,
    }) catch |failure| return respondDownloadFailure(request, failure);
    defer result.deinit(allocator);
    return respondDownloadAction(request, result);
}

fn serveDownloadControl(allocator: std.mem.Allocator, configuration: *const Config, state: *download_manager.State, client: *http.Client, database: *sqlite.Database, request: *http.Server.Request, control: DownloadControl) !bool {
    const suffix = switch (control) {
        .pause => "/pause",
        .@"resume" => "/resume",
        .cancel => "/cancel",
    };
    const id = try pathParameterBetween(allocator, request.head.target, "/studio/downloads/", suffix);
    defer allocator.free(id);
    if (control == .@"resume") {
        const header_token = try capturedDownloadTokenHeader(allocator, request);
        defer if (header_token) |value| allocator.free(value);
        const document = try readBoundedJsonBody(allocator, request) orelse return false;
        defer allocator.free(document);
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, if (document.len > 0) document else "{}", .{}) catch return respondDownloadError(request, .bad_request, "Invalid JSON body");
        defer parsed.deinit();
        if (parsed.value != .object) return respondDownloadError(request, .bad_request, "Invalid JSON body");
        const body_token = optionalDownloadString(parsed.value.object, "hf_token") catch return respondDownloadError(request, .bad_request, "Invalid hf_token");
        const token = downloadToken(configuration.environment, body_token, header_token);
        var result = (state.resumePayload(configuration, client, database, id, token) catch |failure| return respondDownloadFailure(request, failure)) orelse return respondDownloadError(request, .not_found, "Download not found");
        defer result.deinit(allocator);
        return respondDownloadAction(request, result);
    }
    const response = switch (control) {
        .pause => try state.pausePayload(database, id),
        .cancel => try state.cancelPayload(database, id),
        .@"resume" => unreachable,
    } orelse return respondDownloadError(request, .not_found, "Download not found");
    defer allocator.free(response);
    try request.respond(response, .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
    return request.head.keep_alive;
}

fn readBoundedJsonBody(allocator: std.mem.Allocator, request: *http.Server.Request) !?[]u8 {
    const storage = try allocator.alloc(u8, max_settings_request_bytes);
    defer allocator.free(storage);
    var body_writer: Io.Writer = .fixed(storage);
    var request_read_buffer: [16 * 1024]u8 = undefined;
    const body_reader = try request.readerExpectContinue(&request_read_buffer);
    _ = body_reader.streamRemaining(&body_writer) catch {
        try request.respond("{\"detail\":\"Request body is too large\"}", .{ .status = .payload_too_large, .keep_alive = false, .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return null;
    };
    return try allocator.dupe(u8, body_writer.buffered());
}

fn requiredDownloadString(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    const value = object.get(name) orelse return error.MissingDownloadField;
    if (value != .string or std.mem.trim(u8, value.string, " \t\r\n").len == 0) return error.InvalidDownloadField;
    return value.string;
}

fn optionalDownloadString(object: std.json.ObjectMap, name: []const u8) !?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .null => null,
        .string => |text| text,
        else => error.InvalidDownloadField,
    };
}

fn downloadPatterns(allocator: std.mem.Allocator, object: std.json.ObjectMap, name: []const u8) ![]const []const u8 {
    const value = object.get(name) orelse return allocator.alloc([]const u8, 0);
    if (value == .null) return allocator.alloc([]const u8, 0);
    if (value != .array or value.array.items.len > 10_000) return error.InvalidDownloadField;
    var count: usize = 0;
    for (value.array.items) |entry| {
        if (entry != .string) return error.InvalidDownloadField;
        if (entry.string.len > 4096) return error.InvalidDownloadField;
        if (entry.string.len > 0) count += 1;
    }
    const patterns = try allocator.alloc([]const u8, count);
    var index: usize = 0;
    for (value.array.items) |entry| {
        if (entry.string.len == 0) continue;
        patterns[index] = entry.string;
        index += 1;
    }
    return patterns;
}

fn capturedDownloadTokenHeader(allocator: std.mem.Allocator, request: *const http.Server.Request) !?[]u8 {
    if (requestHeader(request, "x-hf-token")) |value| if (value.len > 0) return try allocator.dupe(u8, value);
    if (requestHeader(request, "x-huggingface-token")) |value| if (value.len > 0) return try allocator.dupe(u8, value);
    return null;
}

fn downloadToken(environment: *const std.process.Environ.Map, body_token: ?[]const u8, header_token: ?[]const u8) ?[]const u8 {
    if (body_token) |value| if (value.len > 0) return value;
    if (header_token) |value| return value;
    for ([_][]const u8{ "LOCAL_STUDIO_HF_TOKEN", "HF_TOKEN", "HUGGINGFACE_TOKEN" }) |name| if (environment.get(name)) |value| if (value.len > 0) return value;
    return null;
}

fn respondDownloadAction(request: *http.Server.Request, result: download_manager.Action) !bool {
    switch (result) {
        .payload => |payload| try request.respond(payload, .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} }),
        .conflict => |detail| return respondDownloadError(request, .conflict, detail),
    }
    return request.head.keep_alive;
}

fn respondDownloadFailure(request: *http.Server.Request, failure: anyerror) !bool {
    const status: http.Status = switch (failure) {
        error.ModelIdRequired, error.InvalidDownloadField, error.InvalidDestinationPath, error.NoDownloadableFiles, error.MultipleGgufVariants, error.InvalidHuggingFaceModelInfo => .bad_request,
        error.TooManyActiveDownloads => .service_unavailable,
        error.DownloadRecordTooLarge => .payload_too_large,
        error.HuggingFaceApiError, error.HuggingFaceMetadataTimeout => .bad_gateway,
        else => .internal_server_error,
    };
    const detail: []const u8 = switch (failure) {
        error.ModelIdRequired => "Model id is required",
        error.InvalidDownloadField => "Invalid download request",
        error.InvalidDestinationPath => "Invalid destination path",
        error.NoDownloadableFiles => "No downloadable files found for this model",
        error.MultipleGgufVariants => "Multiple GGUF weight variants found. Choose one file before downloading",
        error.TooManyActiveDownloads => "Too many active downloads",
        error.DownloadRecordTooLarge => "Download metadata is too large",
        error.HuggingFaceApiError => "Hugging Face API error",
        error.HuggingFaceMetadataTimeout => "Hugging Face API request timed out",
        else => @errorName(failure),
    };
    return respondDownloadError(request, status, detail);
}

fn respondDownloadError(request: *http.Server.Request, status: http.Status, detail: []const u8) !bool {
    var buffer: [8192]u8 = undefined;
    var output: Io.Writer = .fixed(&buffer);
    try output.writeAll("{\"detail\":");
    try std.json.Stringify.value(detail, .{}, &output);
    try output.writeByte('}');
    try request.respond(output.buffered(), .{ .status = status, .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
    return request.head.keep_alive;
}

fn respondProviderFailure(request: *http.Server.Request, failure: anyerror, provider_id: ?[]const u8) !bool {
    const status: http.Status = switch (failure) {
        error.ProviderNotFound => .not_found,
        error.ProviderSettingsTooLarge => .payload_too_large,
        error.InvalidProviderPayload, error.ProviderIdRequired, error.ProviderNameRequired, error.ProviderBaseUrlRequired, error.ProviderExists, error.TooManyProviders, error.InvalidProvider, error.ProviderFieldTooLarge => .bad_request,
        else => return failure,
    };
    const static_detail: []const u8 = switch (failure) {
        error.InvalidProviderPayload => "Invalid provider payload",
        error.ProviderIdRequired => "id is required",
        error.ProviderNameRequired => "name is required",
        error.ProviderBaseUrlRequired => "base_url is required",
        error.ProviderExists => "Provider already exists",
        error.TooManyProviders => "Too many providers",
        error.InvalidProvider => "Invalid provider",
        error.ProviderFieldTooLarge => "Provider field is too large",
        error.ProviderSettingsTooLarge => "Provider settings are too large",
        error.ProviderNotFound => "Provider not found",
        else => unreachable,
    };
    if (failure != error.ProviderNotFound or provider_id == null or provider_id.?.len > 2048) return respondDownloadError(request, status, static_detail);
    var buffer: [4096]u8 = undefined;
    var output: Io.Writer = .fixed(&buffer);
    try output.print("Provider \"{s}\" not found", .{provider_id.?});
    return respondDownloadError(request, status, output.buffered());
}

fn serveStudioSettingsUpdate(allocator: std.mem.Allocator, io: Io, configuration: *const Config, studio: *studio_settings.State, database: *sqlite.Database, request: *http.Server.Request) !bool {
    const storage = try allocator.alloc(u8, max_settings_request_bytes);
    defer allocator.free(storage);
    var body_writer: Io.Writer = .fixed(storage);
    var request_read_buffer: [16 * 1024]u8 = undefined;
    const body_reader = try request.readerExpectContinue(&request_read_buffer);
    _ = body_reader.streamRemaining(&body_writer) catch {
        try request.respond("{\"detail\":\"Request body is too large\"}", .{
            .status = .payload_too_large,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        });
        return false;
    };
    const response = studio_settings.updatePayload(allocator, io, configuration, studio, database, body_writer.buffered()) catch |failure| {
        const detail = switch (failure) {
            error.InvalidSettingsPayload => "Invalid JSON body",
            error.NoSupportedSettings => "No supported settings provided",
            error.InvalidModelsDirectory => "models_dir must be a string or null",
            error.InvalidUiPreferences => "ui_preferences must be an object of string values or null",
            else => return failure,
        };
        var output: Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        try output.writer.writeAll("{\"detail\":");
        try std.json.Stringify.value(detail, .{}, &output.writer);
        try output.writer.writeByte('}');
        try request.respond(output.writer.buffered(), .{ .status = .bad_request, .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return request.head.keep_alive;
    };
    defer allocator.free(response);
    try request.respond(response, .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
    return request.head.keep_alive;
}

fn serveVramCalculator(allocator: std.mem.Allocator, io: Io, configuration: *const Config, system: *const system_info.Snapshot, request: *http.Server.Request) !bool {
    const storage = try allocator.alloc(u8, max_settings_request_bytes);
    defer allocator.free(storage);
    var body_writer: Io.Writer = .fixed(storage);
    var request_read_buffer: [16 * 1024]u8 = undefined;
    const body_reader = try request.readerExpectContinue(&request_read_buffer);
    _ = body_reader.streamRemaining(&body_writer) catch {
        try request.respond("{\"detail\":\"Request body is too large\"}", .{ .status = .payload_too_large, .keep_alive = false, .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return false;
    };
    const response = vram_calculator.payload(allocator, io, system, configuration.models_dir, body_writer.buffered()) catch |failure| {
        const detail: []const u8 = switch (failure) {
            error.InvalidPayload => "Invalid payload",
            error.ModelRequired => "model is required",
            error.ModelOutsideRoot => "model must be inside models_dir",
            error.ModelNotFound => "Model path not found",
            error.WeightsNotFound => "Model weights not found",
            else => return failure,
        };
        const status: http.Status = switch (failure) {
            error.ModelNotFound, error.WeightsNotFound => .not_found,
            else => .bad_request,
        };
        var output: Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        try output.writer.writeAll("{\"detail\":");
        try std.json.Stringify.value(detail, .{}, &output.writer);
        try output.writer.writeByte('}');
        try request.respond(output.writer.buffered(), .{ .status = status, .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return request.head.keep_alive;
    };
    defer allocator.free(response);
    try request.respond(response, .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
    return request.head.keep_alive;
}

fn serveRuntimeJobCreate(allocator: std.mem.Allocator, configuration: *const Config, jobs: *runtime_jobs_service.State, cache: *runtime_info.Cache, request: *http.Server.Request, backend_override: ?[]const u8, legacy: bool) !bool {
    const storage = try allocator.alloc(u8, max_settings_request_bytes);
    defer allocator.free(storage);
    var body_writer: Io.Writer = .fixed(storage);
    var request_read_buffer: [16 * 1024]u8 = undefined;
    const body_reader = try request.readerExpectContinue(&request_read_buffer);
    _ = body_reader.streamRemaining(&body_writer) catch {
        try request.respond("{\"detail\":\"Request body is too large\"}", .{ .status = .payload_too_large, .keep_alive = false, .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return false;
    };
    const document = if (body_writer.buffered().len == 0) "{}" else body_writer.buffered();
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, document, .{}) catch return respondBadRuntimeJob(request, "Invalid payload");
    defer parsed.deinit();
    if (parsed.value != .object) return respondBadRuntimeJob(request, "Invalid payload");
    const object = parsed.value.object;
    if (object.get("command") != null or object.get("args") != null) return respondBadRuntimeJob(request, "Invalid payload");
    const payload_backend = runtimeJobOptionalString(object, "backend") catch return respondBadRuntimeJob(request, "Invalid payload");
    const backend = backend_override orelse payload_backend orelse return respondBadRuntimeJob(request, "backend is required");
    if (!runtimeJobBackend(backend)) return respondBadRuntimeJob(request, "Invalid payload");
    const payload_type = runtimeJobOptionalString(object, "type") catch return respondBadRuntimeJob(request, "Invalid payload");
    const job_type = if (legacy) "update" else payload_type orelse "update";
    if (!std.mem.eql(u8, job_type, "install") and !std.mem.eql(u8, job_type, "update")) return respondBadRuntimeJob(request, "Invalid payload");
    const target_id = runtimeJobOptionalString(object, "targetId") catch return respondBadRuntimeJob(request, "Invalid payload");
    const version = runtimeJobOptionalString(object, "version") catch return respondBadRuntimeJob(request, "Invalid payload");
    const prefer_bundled = if (object.get("prefer_bundled")) |value| if (value == .bool) value.bool else return respondBadRuntimeJob(request, "Invalid payload") else null;
    const response = jobs.createPayload(configuration, cache, .{
        .backend = backend,
        .job_type = job_type,
        .target_id = target_id,
        .version = version,
        .prefer_bundled = prefer_bundled,
    }, legacy) catch |failure| switch (failure) {
        error.InvalidJobPayload => return respondBadRuntimeJob(request, "Invalid payload"),
        error.TooManyRuntimeJobs => {
            try request.respond("{\"detail\":\"Too many runtime jobs\"}", .{ .status = .service_unavailable, .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
            return request.head.keep_alive;
        },
        else => return failure,
    };
    defer allocator.free(response);
    try request.respond(response, .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
    return request.head.keep_alive;
}

fn respondBadRuntimeJob(request: *http.Server.Request, detail: []const u8) !bool {
    var buffer: [256]u8 = undefined;
    var output: Io.Writer = .fixed(&buffer);
    try output.writeAll("{\"detail\":");
    try std.json.Stringify.value(detail, .{}, &output);
    try output.writeByte('}');
    try request.respond(output.buffered(), .{ .status = .bad_request, .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
    return request.head.keep_alive;
}

fn runtimeJobOptionalString(object: std.json.ObjectMap, name: []const u8) !?[]const u8 {
    const value = object.get(name) orelse return null;
    if (value != .string) return error.InvalidRuntimeJobField;
    return value.string;
}

fn runtimeJobBackend(value: []const u8) bool {
    for ([_][]const u8{ "vllm", "sglang", "llamacpp", "mlx", "cuda", "rocm" }) |backend| if (std.mem.eql(u8, value, backend)) return true;
    return false;
}

const ModelMutation = enum { delete, move };

fn serveStudioModelMutation(allocator: std.mem.Allocator, io: Io, studio: *studio_settings.State, request: *http.Server.Request, mutation: ModelMutation) !bool {
    const storage = try allocator.alloc(u8, max_settings_request_bytes);
    defer allocator.free(storage);
    var body_writer: Io.Writer = .fixed(storage);
    var request_read_buffer: [16 * 1024]u8 = undefined;
    const body_reader = try request.readerExpectContinue(&request_read_buffer);
    _ = body_reader.streamRemaining(&body_writer) catch {
        try request.respond("{\"detail\":\"Request body is too large\"}", .{
            .status = .payload_too_large,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        });
        return false;
    };
    const models_dir = try studio.modelsDirectory(allocator, io);
    defer allocator.free(models_dir);
    try studio.lockFiles(io);
    defer studio.unlockFiles(io);
    const response = switch (mutation) {
        .delete => model_files.deletePayload(allocator, io, models_dir, body_writer.buffered()),
        .move => model_files.movePayload(allocator, io, models_dir, body_writer.buffered()),
    } catch |failure| {
        const known: ?struct { []const u8, http.Status } = switch (failure) {
            error.InvalidPayload => .{ "Invalid JSON body", .bad_request },
            error.PathRequired => .{ "path is required", .bad_request },
            error.MovePathsRequired => .{ "source_path and target_root are required", .bad_request },
            error.PathOutsideModelsDirectory => .{ "path must be inside models_dir", .bad_request },
            error.SourceOutsideModelsDirectory => .{ "source_path must be inside models_dir", .bad_request },
            error.TargetOutsideModelsDirectory => .{ "target_root must be inside models_dir", .bad_request },
            error.ModelPathNotFound => .{ "Model path not found", .not_found },
            error.SourcePathNotFound => .{ "source_path not found", .not_found },
            error.TargetPathExists => .{ "Target path already exists", .bad_request },
            else => null,
        };
        const detail = if (known) |value| value[0] else "Internal Server Error";
        const status = if (known) |value| value[1] else .internal_server_error;
        var output: Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        try output.writer.writeAll("{\"detail\":");
        try std.json.Stringify.value(detail, .{}, &output.writer);
        try output.writer.writeByte('}');
        try request.respond(output.writer.buffered(), .{ .status = status, .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return request.head.keep_alive;
    };
    defer allocator.free(response);
    try request.respond(response, .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
    return request.head.keep_alive;
}

fn serveModelIndex(allocator: std.mem.Allocator, configuration: *const Config, cache: *model_index.Cache, request: *http.Server.Request) !bool {
    const response = cache.payload(allocator, configuration.data_dir) catch |failure| {
        const index_path = try model_index.path(allocator, configuration.data_dir);
        defer allocator.free(index_path);
        const detail = switch (failure) {
            error.ModelIndexInvalidJson => try std.fmt.allocPrint(allocator, "Model index at {s} is not valid JSON", .{index_path}),
            error.ModelIndexInvalidSchema => try std.fmt.allocPrint(allocator, "Model index at {s} failed validation", .{index_path}),
            else => try std.fmt.allocPrint(allocator, "Could not read model index at {s}", .{index_path}),
        };
        defer allocator.free(detail);
        var output: Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        try output.writer.writeAll("{\"detail\":");
        try std.json.Stringify.value(detail, .{}, &output.writer);
        try output.writer.writeByte('}');
        try request.respond(output.writer.buffered(), .{ .status = .internal_server_error, .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return request.head.keep_alive;
    };
    defer allocator.free(response);
    try request.respond(response, .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
    return request.head.keep_alive;
}

fn serveRuntimeBackend(allocator: std.mem.Allocator, configuration: *const Config, system: *const system_info.Snapshot, cache: *runtime_info.Cache, backend: runtime_routes.Backend, request: *http.Server.Request) !bool {
    const response = try runtime_routes.backendPayload(allocator, configuration, system, cache, backend);
    defer allocator.free(response);
    try request.respond(response, .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
    return request.head.keep_alive;
}

fn serveRuntimeConfigHelp(allocator: std.mem.Allocator, io: Io, configuration: *const Config, backend: runtime_routes.Backend, request: *http.Server.Request) !bool {
    const response = try runtime_routes.configHelpPayload(allocator, io, configuration, backend);
    defer allocator.free(response);
    try request.respond(response, .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
    return request.head.keep_alive;
}

fn serveHeadInference(allocator: std.mem.Allocator, io: Io, configuration: *const Config, studio: *studio_settings.State, client: *http.Client, database: *sqlite.Database, worker_pool: *worker_service.Pool, request: *http.Server.Request) !bool {
    var captured = try reverse_proxy.captureRequest(allocator, request);
    defer captured.deinit();
    const storage = try allocator.alloc(u8, max_chat_request_bytes);
    defer allocator.free(storage);
    var body_writer: Io.Writer = .fixed(storage);
    var request_read_buffer: [16 * 1024]u8 = undefined;
    const body_reader = try request.readerExpectContinue(&request_read_buffer);
    _ = body_reader.streamRemaining(&body_writer) catch {
        try request.respond("{\"detail\":\"Request body is too large\"}", .{
            .status = .payload_too_large,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        });
        return false;
    };
    const body = body_writer.buffered();
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        try request.respond("{\"detail\":\"Invalid JSON body\"}", .{
            .status = .bad_request,
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        });
        return request.head.keep_alive;
    };
    defer parsed.deinit();
    if (parsed.value != .object) return try respondModelRequired(request);
    const model_value = parsed.value.object.get("model") orelse return try respondModelRequired(request);
    if (model_value != .string) return try respondModelRequired(request);
    const model_id = std.mem.trim(u8, model_value.string, " \t\r\n");
    if (model_id.len == 0) return try respondModelRequired(request);

    var snapshot = try provider_service.loadSnapshot(allocator, io, studio, configuration.data_dir);
    defer snapshot.deinit();
    if (provider_routing.resolve(snapshot.providers, model_id)) |provider_route| {
        const rewritten = try provider_routing.rewriteModel(allocator, &parsed, provider_route.model_id);
        defer allocator.free(rewritten);
        const accept: ?[]const u8 = if (parsed.value.object.get("stream")) |stream_value| if (stream_value == .bool and stream_value.bool) "text/event-stream" else "application/json" else "application/json";
        reverse_proxy.serveProviderBuffered(allocator, client, provider_route.provider.base_url, provider_route.provider.api_key, rewritten, &captured, request, accept, false) catch return false;
        return false;
    }

    if (!worker_pool.tryAcquireInference()) {
        try request.respond("{\"detail\":\"Inference request capacity is exhausted\"}", .{
            .status = .service_unavailable,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        });
        return false;
    }
    defer worker_pool.releaseInference();

    var worker = worker_service.selectServing(allocator, io, client, database, worker_pool, model_id, null) catch null orelse {
        return try respondModelNotRunning(allocator, request, null, model_id);
    };
    defer worker.deinit();
    try worker_pool.acquire(io, worker.id);
    reverse_proxy.serveWorkerBuffered(allocator, client, worker.address, worker.api_key, worker.id, body, &captured, request) catch |failure| {
        worker_pool.release(io, worker.id);
        if (failure == error.WorkerStreamFailedAfterCommitment) return false;
        var alternate = worker_service.selectServing(allocator, io, client, database, worker_pool, model_id, worker.id) catch null orelse {
            try request.respond("{\"detail\":\"Worker is unavailable\"}", .{
                .status = .bad_gateway,
                .keep_alive = false,
                .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
            });
            return false;
        };
        defer alternate.deinit();
        try worker_pool.acquire(io, alternate.id);
        reverse_proxy.serveWorkerBuffered(allocator, client, alternate.address, alternate.api_key, alternate.id, body, &captured, request) catch |retry_failure| {
            worker_pool.release(io, alternate.id);
            if (retry_failure == error.WorkerStreamFailedAfterCommitment) return false;
            try request.respond("{\"detail\":\"Worker is unavailable\"}", .{
                .status = .bad_gateway,
                .keep_alive = false,
                .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
            });
            return false;
        };
        worker_pool.release(io, alternate.id);
        return false;
    };
    worker_pool.release(io, worker.id);
    return false;
}

fn serveLocalChat(allocator: std.mem.Allocator, io: Io, configuration: *const Config, studio: *studio_settings.State, client: *http.Client, database: *sqlite.Database, recipe_column: recipes.PayloadColumn, llm_instance_path: []const u8, request: *http.Server.Request, inference_origin: []const u8) !bool {
    var captured = try reverse_proxy.captureRequest(allocator, request);
    defer captured.deinit();
    const storage = try allocator.alloc(u8, max_chat_request_bytes);
    defer allocator.free(storage);
    var body_writer: Io.Writer = .fixed(storage);
    var request_read_buffer: [16 * 1024]u8 = undefined;
    const body_reader = try request.readerExpectContinue(&request_read_buffer);
    _ = body_reader.streamRemaining(&body_writer) catch {
        try request.respond("{\"detail\":\"Request body is too large\"}", .{
            .status = .payload_too_large,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        });
        return false;
    };
    const body = body_writer.buffered();
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        try request.respond("{\"detail\":\"Invalid JSON body\"}", .{
            .status = .bad_request,
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        });
        return request.head.keep_alive;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        try request.respond("{\"detail\":\"Invalid JSON body\"}", .{
            .status = .bad_request,
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        });
        return request.head.keep_alive;
    }

    const requested_provider_model = if (parsed.value.object.get("model")) |value| if (value == .string) std.mem.trim(u8, value.string, " \t\r\n") else "" else "";
    var snapshot = try provider_service.loadSnapshot(allocator, io, studio, configuration.data_dir);
    defer snapshot.deinit();
    if (provider_routing.resolve(snapshot.providers, requested_provider_model)) |provider_route| {
        const rewritten_provider = try provider_routing.rewriteModel(allocator, &parsed, provider_route.model_id);
        defer allocator.free(rewritten_provider);
        const accept: ?[]const u8 = if (parsed.value.object.get("stream")) |stream_value| if (stream_value == .bool and stream_value.bool) "text/event-stream" else "application/json" else "application/json";
        reverse_proxy.serveProviderBuffered(allocator, client, provider_route.provider.base_url, provider_route.provider.api_key, rewritten_provider, &captured, request, accept, false) catch return false;
        return false;
    }

    var rewritten: ?[]u8 = null;
    defer if (rewritten) |payload| allocator.free(payload);
    if (parsed.value.object.get("model")) |model_value| {
        if (model_value == .string) {
            const requested_model = std.mem.trim(u8, model_value.string, " \t\r\n");
            if (requested_model.len > 0) {
                var resolution = try model_service.resolveRequestedModel(allocator, io, database, recipe_column, llm_instance_path, requested_model);
                defer resolution.deinit();
                if (resolution.managed and !resolution.active) return try respondModelNotRunning(allocator, request, resolution.active_model, requested_model);
                if (resolution.canonical) |canonical| {
                    if (!std.mem.eql(u8, canonical, requested_model)) {
                        try parsed.value.object.put(parsed.arena.allocator(), "model", .{ .string = canonical });
                        var output: Io.Writer.Allocating = .init(allocator);
                        errdefer output.deinit();
                        try std.json.Stringify.value(parsed.value, .{}, &output.writer);
                        rewritten = try output.toOwnedSlice();
                    }
                }
            }
        }
    }
    reverse_proxy.serveLocalBuffered(client, inference_origin, rewritten orelse body, &captured, request, null) catch return false;
    return false;
}

const LocalProtocol = enum {
    responses,
    messages,
};

fn serveLocalPassthrough(allocator: std.mem.Allocator, io: Io, configuration: *const Config, studio: *studio_settings.State, client: *http.Client, database: *sqlite.Database, recipe_column: recipes.PayloadColumn, llm_instance_path: []const u8, request: *http.Server.Request, inference_origin: []const u8, protocol: LocalProtocol) !bool {
    var captured = try reverse_proxy.captureRequest(allocator, request);
    defer captured.deinit();
    const storage = try allocator.alloc(u8, max_chat_request_bytes);
    defer allocator.free(storage);
    var body_writer: Io.Writer = .fixed(storage);
    var request_read_buffer: [16 * 1024]u8 = undefined;
    const body_reader = try request.readerExpectContinue(&request_read_buffer);
    _ = body_reader.streamRemaining(&body_writer) catch {
        try request.respond("{\"detail\":\"Request body is too large\"}", .{
            .status = .payload_too_large,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        });
        return false;
    };
    const body = body_writer.buffered();
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return try respondInvalidProtocolBody(request, protocol);
    defer parsed.deinit();
    if (parsed.value != .object) return try respondInvalidProtocolBody(request, protocol);

    const model_value = parsed.value.object.get("model");
    const requested_model = if (model_value != null and model_value.? == .string)
        std.mem.trim(u8, model_value.?.string, " \t\r\n")
    else
        "";
    if (protocol == .responses and requested_model.len == 0) {
        try request.respond("{\"detail\":\"Responses request requires a model\"}", .{
            .status = .bad_request,
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        });
        return request.head.keep_alive;
    }

    var snapshot = try provider_service.loadSnapshot(allocator, io, studio, configuration.data_dir);
    defer snapshot.deinit();
    if (provider_routing.resolve(snapshot.providers, requested_model)) |provider_route| {
        const rewritten_provider = try provider_routing.rewriteModel(allocator, &parsed, provider_route.model_id);
        defer allocator.free(rewritten_provider);
        const accept: ?[]const u8 = if (parsed.value.object.get("stream")) |stream_value| if (stream_value == .bool and stream_value.bool) "text/event-stream" else "application/json" else "application/json";
        reverse_proxy.serveProviderBuffered(allocator, client, provider_route.provider.base_url, provider_route.provider.api_key, rewritten_provider, &captured, request, accept, protocol == .messages) catch return false;
        return false;
    }

    var rewritten: ?[]u8 = null;
    defer if (rewritten) |payload| allocator.free(payload);
    if (requested_model.len > 0) {
        var resolution = try model_service.resolveRequestedModel(allocator, io, database, recipe_column, llm_instance_path, requested_model);
        defer resolution.deinit();
        if (resolution.canonical) |canonical| {
            if (!std.mem.eql(u8, canonical, requested_model)) {
                try parsed.value.object.put(parsed.arena.allocator(), "model", .{ .string = canonical });
                var output: Io.Writer.Allocating = .init(allocator);
                errdefer output.deinit();
                try std.json.Stringify.value(parsed.value, .{}, &output.writer);
                rewritten = try output.toOwnedSlice();
            }
        }
    }
    const accept: ?[]const u8 = if (protocol == .responses)
        if (parsed.value.object.get("stream")) |stream_value| if (stream_value == .bool and stream_value.bool) "text/event-stream" else "application/json" else "application/json"
    else
        null;
    reverse_proxy.serveLocalBuffered(client, inference_origin, rewritten orelse body, &captured, request, accept) catch return false;
    return false;
}

fn respondInvalidProtocolBody(request: *http.Server.Request, protocol: LocalProtocol) !bool {
    const body = switch (protocol) {
        .responses => "{\"detail\":\"Invalid Responses request body\"}",
        .messages => "{\"detail\":\"Invalid JSON request body\"}",
    };
    try request.respond(body, .{
        .status = .bad_request,
        .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
    });
    return request.head.keep_alive;
}

const TokenizationProtocol = enum {
    count,
    chat,
};

fn serveTokenization(allocator: std.mem.Allocator, io: Io, client: *http.Client, database: *sqlite.Database, recipe_column: recipes.PayloadColumn, llm_instance_path: []const u8, request: *http.Server.Request, inference_origin: []const u8, protocol: TokenizationProtocol) !bool {
    const storage = try allocator.alloc(u8, max_chat_request_bytes);
    defer allocator.free(storage);
    var body_writer: Io.Writer = .fixed(storage);
    var request_read_buffer: [16 * 1024]u8 = undefined;
    const body_reader = try request.readerExpectContinue(&request_read_buffer);
    _ = body_reader.streamRemaining(&body_writer) catch {
        try request.respond("{\"detail\":\"Request body is too large\"}", .{
            .status = .payload_too_large,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        });
        return false;
    };
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body_writer.buffered(), .{}) catch return try respondInvalidPayload(request);
    defer parsed.deinit();
    if (parsed.value != .object) return try respondInvalidPayload(request);
    const valid = switch (protocol) {
        .count => tokenization_service.validCountRequest(parsed.value.object),
        .chat => tokenization_service.validChatRequest(parsed.value.object),
    };
    if (!valid) return try respondInvalidPayload(request);

    const active_model = try model_service.activeModelId(allocator, io, database, recipe_column, llm_instance_path) orelse {
        const empty = switch (protocol) {
            .count => "{\"error\":\"No model running\",\"num_tokens\":0}",
            .chat => "{\"error\":\"No model running\",\"input_tokens\":0}",
        };
        try request.respond(empty, .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return request.head.keep_alive;
    };
    defer allocator.free(active_model);
    const payload = switch (protocol) {
        .count => try tokenization_service.countPayload(allocator, client, inference_origin, active_model, parsed.value.object),
        .chat => try tokenization_service.chatPayload(allocator, client, inference_origin, active_model, parsed.value.object),
    };
    defer allocator.free(payload);
    try request.respond(payload, .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
    return request.head.keep_alive;
}

fn respondInvalidPayload(request: *http.Server.Request) !bool {
    try request.respond("{\"detail\":\"Invalid payload\"}", .{
        .status = .bad_request,
        .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
    });
    return request.head.keep_alive;
}

fn respondLifecycleFailure(request: *http.Server.Request, failure: anyerror) !bool {
    const status: http.Status = switch (failure) {
        error.RecipeNotFound => .not_found,
        error.AlreadyRunning, error.PortInUse => .conflict,
        error.UnsupportedBackend, error.UnsupportedPlatform, error.DockerRuntimeNotImplemented => .unprocessable_entity,
        error.LaunchCancelled => .bad_request,
        else => .service_unavailable,
    };
    const detail = switch (failure) {
        error.RecipeNotFound => "Recipe not found",
        error.AlreadyRunning => "llm is already running",
        error.PortInUse => "inference port is already in use",
        error.UnsupportedBackend => "Engine backend is not supported",
        error.UnsupportedPlatform => "Engine cannot run on this host",
        error.DockerRuntimeNotImplemented => "Docker runtime is not available",
        error.LaunchCancelled => "launch cancelled",
        error.ProcessExitedEarly => "process exited before becoming healthy",
        error.ReadinessTimeout => "process did not become healthy before its deadline",
        else => @errorName(failure),
    };
    var buffer: [256]u8 = undefined;
    var output: Io.Writer = .fixed(&buffer);
    try output.writeAll("{\"detail\":");
    try std.json.Stringify.value(detail, .{}, &output);
    try output.writeByte('}');
    try request.respond(output.buffered(), .{ .status = status, .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
    return request.head.keep_alive;
}

fn saveRecipe(allocator: std.mem.Allocator, io: Io, database: *sqlite.Database, recipe_column: recipes.PayloadColumn, request: *http.Server.Request, override_id: ?[]const u8, default_trust_remote_code: bool) !bool {
    const storage = try allocator.alloc(u8, max_chat_request_bytes);
    defer allocator.free(storage);
    var body_writer: Io.Writer = .fixed(storage);
    var request_read_buffer: [16 * 1024]u8 = undefined;
    const body_reader = try request.readerExpectContinue(&request_read_buffer);
    _ = body_reader.streamRemaining(&body_writer) catch {
        try request.respond("{\"detail\":\"Request body is too large\"}", .{
            .status = .payload_too_large,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        });
        return false;
    };
    const id = recipe_service.savePayload(allocator, io, database, recipe_column, body_writer.buffered(), override_id, default_trust_remote_code) catch |failure| {
        var output: Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        try output.writer.writeAll("{\"detail\":");
        try std.json.Stringify.value(@errorName(failure), .{}, &output.writer);
        try output.writer.writeByte('}');
        try request.respond(output.writer.buffered(), .{
            .status = .bad_request,
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        });
        return request.head.keep_alive;
    };
    defer allocator.free(id);
    var output: Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try output.writer.writeAll("{\"success\":true,\"id\":");
    try std.json.Stringify.value(id, .{}, &output.writer);
    try output.writer.writeByte('}');
    try request.respond(output.writer.buffered(), .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
    return request.head.keep_alive;
}

fn respondModelRequired(request: *http.Server.Request) !bool {
    try request.respond("{\"detail\":\"model is required\"}", .{
        .status = .bad_request,
        .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
    });
    return request.head.keep_alive;
}

fn respondModelNotRunning(allocator: std.mem.Allocator, request: *http.Server.Request, active_model: ?[]const u8, model_id: []const u8) !bool {
    const message = if (active_model) |active|
        try std.fmt.allocPrint(allocator, "Model {s} is running; {s} is not. Launch it from the frontend before sending requests.", .{ active, model_id })
    else
        try std.fmt.allocPrint(allocator, "No model is running. Launch {s} from the frontend before sending requests.", .{model_id});
    defer allocator.free(message);
    var output: Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try output.writer.writeAll("{\"error\":{\"message\":");
    try std.json.Stringify.value(message, .{}, &output.writer);
    try output.writer.writeAll(",\"type\":\"model_not_running\",\"code\":\"model_not_running\"},\"detail\":");
    try std.json.Stringify.value(message, .{}, &output.writer);
    try output.writer.writeByte('}');
    try request.respond(output.writer.buffered(), .{
        .status = .service_unavailable,
        .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
    });
    return request.head.keep_alive;
}

fn serveWorkerProxy(allocator: std.mem.Allocator, io: Io, client: *http.Client, database: *sqlite.Database, request: *http.Server.Request) !bool {
    if (requestHeader(request, "X-Local-Studio-Federation-Hop") != null) {
        try request.respond("{\"detail\":\"Federation loop rejected\"}", .{
            .status = .loop_detected,
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        });
        return request.head.keep_alive;
    }
    const worker_id = requestHeader(request, "X-Local-Studio-Worker-Id") orelse {
        try request.respond("{\"detail\":\"Select a Worker before using this controller endpoint\"}", .{
            .status = .conflict,
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        });
        return request.head.keep_alive;
    };
    const normalized_worker_id = std.mem.trim(u8, worker_id, " \t");
    if (normalized_worker_id.len == 0) {
        try request.respond("{\"detail\":\"Select a Worker before using this controller endpoint\"}", .{
            .status = .conflict,
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        });
        return request.head.keep_alive;
    }
    var target = worker_service.findTarget(allocator, io, database, normalized_worker_id) catch {
        try request.respond("{\"detail\":\"Worker configuration unavailable\"}", .{
            .status = .internal_server_error,
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        });
        return request.head.keep_alive;
    } orelse {
        try request.respond("{\"detail\":\"Selected Worker was not found\"}", .{
            .status = .not_found,
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        });
        return request.head.keep_alive;
    };
    defer target.deinit();
    try reverse_proxy.serveWorker(allocator, client, target.address, target.api_key, target.id, request);
    return false;
}

fn requestHeader(request: *const http.Server.Request, expected_name: []const u8) ?[]const u8 {
    var iterator = request.iterateHeaders();
    while (iterator.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, expected_name)) return header.value;
    }
    return null;
}

fn pathParameter(allocator: std.mem.Allocator, target: []const u8, prefix: []const u8) ![]u8 {
    const query_start = std.mem.findScalar(u8, target, '?') orelse target.len;
    const path = target[0..query_start];
    if (!std.mem.startsWith(u8, path, prefix) or path.len <= prefix.len) return error.InvalidPathParameter;
    const encoded = path[prefix.len..];
    const storage = try allocator.dupe(u8, encoded);
    defer allocator.free(storage);
    return try allocator.dupe(u8, std.Uri.percentDecodeInPlace(storage));
}

fn pathParameterBetween(allocator: std.mem.Allocator, target: []const u8, prefix: []const u8, suffix: []const u8) ![]u8 {
    const query_start = std.mem.findScalar(u8, target, '?') orelse target.len;
    const path = target[0..query_start];
    if (!std.mem.startsWith(u8, path, prefix) or !std.mem.endsWith(u8, path, suffix) or path.len <= prefix.len + suffix.len) return error.InvalidPathParameter;
    const encoded = path[prefix.len .. path.len - suffix.len];
    const storage = try allocator.dupe(u8, encoded);
    defer allocator.free(storage);
    return try allocator.dupe(u8, std.Uri.percentDecodeInPlace(storage));
}

fn queryUnsigned(target: []const u8, expected_name: []const u8) ?u64 {
    const query_start = std.mem.findScalar(u8, target, '?') orelse return null;
    var parameters = std.mem.splitScalar(u8, target[query_start + 1 ..], '&');
    while (parameters.next()) |parameter| {
        const separator = std.mem.findScalar(u8, parameter, '=') orelse continue;
        if (!std.mem.eql(u8, parameter[0..separator], expected_name)) continue;
        return std.fmt.parseInt(u64, parameter[separator + 1 ..], 10) catch null;
    }
    return null;
}

fn queryParameter(allocator: std.mem.Allocator, target: []const u8, expected_name: []const u8) !?[]u8 {
    const query_start = std.mem.findScalar(u8, target, '?') orelse return null;
    var parameters = std.mem.splitScalar(u8, target[query_start + 1 ..], '&');
    while (parameters.next()) |parameter| {
        const separator = std.mem.findScalar(u8, parameter, '=') orelse {
            if (std.mem.eql(u8, parameter, expected_name)) return @as(?[]u8, try allocator.dupe(u8, ""));
            continue;
        };
        if (!std.mem.eql(u8, parameter[0..separator], expected_name)) continue;
        const encoded = parameter[separator + 1 ..];
        const storage = try allocator.dupe(u8, encoded);
        defer allocator.free(storage);
        for (storage) |*character| if (character.* == '+') {
            character.* = ' ';
        };
        return @as(?[]u8, try allocator.dupe(u8, std.Uri.percentDecodeInPlace(storage)));
    }
    return null;
}

fn trimmedOptional(value: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    return if (trimmed.len == 0) null else trimmed;
}

fn serveSse(io: Io, request: *http.Server.Request) !void {
    var stream_buffer: [4096]u8 = undefined;
    var body = try request.respondStreaming(&stream_buffer, .{
        .respond_options = .{
            .keep_alive = false,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/event-stream" },
                .{ .name = "Cache-Control", .value = "no-cache, no-transform" },
                .{ .name = "X-Accel-Buffering", .value = "no" },
            },
        },
    });

    var sequence: u64 = 0;
    while (true) : (sequence += 1) {
        try body.writer.print("id: {d}\nevent: spike\ndata: {{\"sequence\":{d}}}\n\n", .{ sequence, sequence });
        try body.writer.flush();
        try body.flush();
        try io.sleep(.fromSeconds(1), .awake);
    }
}

fn serveControllerEvents(allocator: std.mem.Allocator, io: Io, client: *http.Client, database: *sqlite.Database, recipe_column: recipes.PayloadColumn, configuration: *const Config, studio: *studio_settings.State, default_trust_remote_code: bool, system: *const system_info.Snapshot, supervisor: *lifecycle.Supervisor, runtime_cache: *runtime_info.Cache, request: *http.Server.Request) !void {
    var stream_buffer: [16 * 1024]u8 = undefined;
    var body = try request.respondStreaming(&stream_buffer, .{
        .respond_options = .{
            .keep_alive = false,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/event-stream" },
                .{ .name = "Cache-Control", .value = "no-cache, no-transform" },
                .{ .name = "X-Accel-Buffering", .value = "no" },
            },
        },
    });
    var sequence: u64 = 0;
    var runtime_at: ?Io.Timestamp = null;
    while (true) {
        const status = try supervisor.statusPayload(database, recipe_column, configuration.inference_port, default_trust_remote_code);
        defer allocator.free(status);
        try writeControllerEvent(io, &body, "status", status, &sequence);

        const gpu = try telemetry.gpuPayload(allocator, io, system);
        defer allocator.free(gpu);
        try writeControllerEvent(io, &body, "gpu", gpu, &sequence);

        const current_metrics = try metrics.payload(allocator, io, client, database, recipe_column, configuration.inference_port, default_trust_remote_code, system, supervisor);
        defer allocator.free(current_metrics);
        try writeControllerEvent(io, &body, "metrics", current_metrics, &sequence);

        const now = Io.Clock.awake.now(io);
        if (runtime_at == null or runtime_at.?.durationTo(now).toSeconds() >= 30) {
            const models_dir = try studio.modelsDirectory(allocator, io);
            defer allocator.free(models_dir);
            const runtime = try system_service.runtimeSummaryPayload(allocator, io, configuration, models_dir, system, supervisor, runtime_cache, database, recipe_column, default_trust_remote_code);
            defer allocator.free(runtime);
            try writeControllerEvent(io, &body, "runtime_summary", runtime, &sequence);
            runtime_at = now;
        }
        try io.sleep(.fromSeconds(5), .awake);
    }
}

fn writeControllerEvent(io: Io, body: anytype, event_type: []const u8, data: []const u8, sequence: *u64) !void {
    var timestamp_buffer: [24]u8 = undefined;
    const timestamp = eventTimestamp(io, &timestamp_buffer);
    try body.writer.print("id: {d}\nevent: {s}\ndata: {{\"data\":", .{ sequence.*, event_type });
    try body.writer.writeAll(data);
    try body.writer.writeAll(",\"timestamp\":");
    try std.json.Stringify.value(timestamp, .{}, &body.writer);
    try body.writer.writeAll("}\n\n");
    try body.writer.flush();
    try body.flush();
    sequence.* += 1;
}

fn serveLogStream(allocator: std.mem.Allocator, io: Io, configuration: *const Config, session_id: []const u8, log_path: []const u8, replay_limit: usize, request: *http.Server.Request) !void {
    var stream_buffer: [16 * 1024]u8 = undefined;
    var body = try request.respondStreaming(&stream_buffer, .{
        .respond_options = .{
            .keep_alive = false,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/event-stream" },
                .{ .name = "Cache-Control", .value = "no-cache, no-transform" },
                .{ .name = "X-Accel-Buffering", .value = "no" },
            },
        },
    });
    var sequence: u64 = 0;
    if (replay_limit > 0) {
        const replay_document = try logs.tailPayload(allocator, io, configuration, session_id, replay_limit) orelse return;
        defer allocator.free(replay_document);
        var replay = std.json.parseFromSlice(std.json.Value, allocator, replay_document, .{}) catch return error.InvalidLogPayload;
        defer replay.deinit();
        if (replay.value == .object) {
            if (replay.value.object.get("logs")) |lines| if (lines == .array) {
                for (lines.array.items) |line| if (line == .string) try writeLogEvent(allocator, io, &body, session_id, line.string, false, &sequence);
            };
        }
    }
    var stat = try std.Io.Dir.cwd().statFile(io, log_path, .{});
    var offset = stat.size;
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(allocator);
    var heartbeat_ticks: usize = 0;
    while (true) {
        try io.sleep(.fromMilliseconds(500), .awake);
        heartbeat_ticks += 1;
        stat = std.Io.Dir.cwd().statFile(io, log_path, .{}) catch {
            if (heartbeat_ticks >= 30) {
                try body.writer.writeAll(": keep-alive\n\n");
                try body.writer.flush();
                try body.flush();
                heartbeat_ticks = 0;
            }
            continue;
        };
        if (stat.size < offset) {
            offset = 0;
            pending.clearRetainingCapacity();
        }
        if (stat.size == offset) {
            if (heartbeat_ticks >= 30) {
                try body.writer.writeAll(": keep-alive\n\n");
                try body.writer.flush();
                try body.flush();
                heartbeat_ticks = 0;
            }
            continue;
        }
        const maximum_chunk: u64 = 1024 * 1024;
        var read_offset = offset;
        var drop_prefix = false;
        if (stat.size - offset > maximum_chunk) {
            read_offset = stat.size - maximum_chunk;
            drop_prefix = true;
            pending.clearRetainingCapacity();
        }
        const read_length: usize = @intCast(stat.size - read_offset);
        const storage = try allocator.alloc(u8, read_length);
        defer allocator.free(storage);
        var file = try std.Io.Dir.cwd().openFile(io, log_path, .{});
        defer file.close(io);
        const bytes_read = try file.readPositionalAll(io, storage, read_offset);
        offset = read_offset + bytes_read;
        var bytes = storage[0..bytes_read];
        if (drop_prefix) {
            const newline = std.mem.indexOfScalar(u8, bytes, '\n') orelse bytes.len;
            bytes = if (newline < bytes.len) bytes[newline + 1 ..] else bytes[bytes.len..];
        }
        try pending.appendSlice(allocator, bytes);
        var consumed: usize = 0;
        while (std.mem.indexOfScalarPos(u8, pending.items, consumed, '\n')) |newline| {
            const line = std.mem.trimEnd(u8, pending.items[consumed..newline], "\r");
            try writeLogEvent(allocator, io, &body, session_id, line, true, &sequence);
            consumed = newline + 1;
        }
        if (consumed > 0) {
            const remaining = pending.items[consumed..];
            std.mem.copyForwards(u8, pending.items[0..remaining.len], remaining);
            pending.items.len = remaining.len;
        }
        if (pending.items.len > maximum_chunk) pending.clearRetainingCapacity();
        heartbeat_ticks = 0;
    }
}

fn writeLogEvent(allocator: std.mem.Allocator, io: Io, body: anytype, session_id: []const u8, line: []const u8, redact_line: bool, sequence: *u64) !void {
    const safe_line = if (redact_line) try logs.redact(allocator, line) else try allocator.dupe(u8, line);
    defer allocator.free(safe_line);
    const Data = struct {
        session_id: []const u8,
        line: []const u8,
    };
    var output: Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try std.json.Stringify.value(Data{ .session_id = session_id, .line = safe_line }, .{}, &output.writer);
    try writeControllerEvent(io, body, "log", output.writer.buffered(), sequence);
}

fn eventTimestamp(io: Io, buffer: *[24]u8) []const u8 {
    const seconds = Io.Clock.real.now(io).toSeconds();
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(seconds, 0)) };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.000Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    }) catch unreachable;
}
