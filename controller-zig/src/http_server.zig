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
const recipes = @import("repository/recipes.zig");
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
    connection_limiter: ConnectionLimiter = .{},

    pub fn init(allocator: std.mem.Allocator, io: Io, config: Config) !HttpServer {
        const address = try net.IpAddress.parse(config.host, config.port);
        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .listener = try address.listen(io, .{ .reuse_address = true }),
            .client = .{ .allocator = allocator, .io = io },
        };
    }

    pub fn deinit(server: *HttpServer) void {
        server.listener.deinit(server.io);
        server.client.deinit();
    }

    pub fn run(server: *HttpServer, database: *sqlite.Database, recipe_column: recipes.PayloadColumn, system: *const system_info.Snapshot, worker_pool: *worker_service.Pool, supervisor: *lifecycle.Supervisor, runtime_cache: *runtime_info.Cache) !void {
        var group: Io.Group = .init;
        defer group.cancel(server.io);
        while (!shutdown.isRequested()) {
            var stream = server.listener.accept(server.io) catch |failure| {
                if (shutdown.isRequested()) return;
                return failure;
            };
            if (!server.connection_limiter.acquire()) {
                rejectOverloadedConnection(server.io, &stream);
                continue;
            }
            group.concurrent(server.io, serveConnection, .{ server.allocator, server.io, server.config.mode, &server.config, &server.client, database, recipe_column, server.config.llm_instance_path, server.config.inference_port, server.config.inference_origin, server.config.default_trust_remote_code, server.config.environment, system, worker_pool, supervisor, runtime_cache, server.config.spike_upstream, server.config.spike_fallback_upstream, &server.connection_limiter, stream }) catch {
                server.connection_limiter.release();
                stream.close(server.io);
            };
        }
    }
};

fn serveConnection(allocator: std.mem.Allocator, io: Io, mode: Mode, configuration: *const Config, client: *http.Client, database: *sqlite.Database, recipe_column: recipes.PayloadColumn, llm_instance_path: []const u8, inference_port: u16, inference_origin: []const u8, default_trust_remote_code: bool, environment: *const std.process.Environ.Map, system: *const system_info.Snapshot, worker_pool: *worker_service.Pool, supervisor: *lifecycle.Supervisor, runtime_cache: *runtime_info.Cache, spike_upstream: ?[]const u8, spike_fallback_upstream: ?[]const u8, connection_limiter: *ConnectionLimiter, stream: net.Stream) void {
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
        const keep_connection = serveRequest(allocator, io, mode, configuration, client, database, recipe_column, llm_instance_path, inference_port, inference_origin, default_trust_remote_code, environment, system, worker_pool, supervisor, runtime_cache, spike_upstream, spike_fallback_upstream, &request) catch return;
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

fn serveRequest(allocator: std.mem.Allocator, io: Io, mode: Mode, configuration: *const Config, client: *http.Client, database: *sqlite.Database, recipe_column: recipes.PayloadColumn, llm_instance_path: []const u8, inference_port: u16, inference_origin: []const u8, default_trust_remote_code: bool, environment: *const std.process.Environ.Map, system: *const system_info.Snapshot, worker_pool: *worker_service.Pool, supervisor: *lifecycle.Supervisor, runtime_cache: *runtime_info.Cache, spike_upstream: ?[]const u8, spike_fallback_upstream: ?[]const u8, request: *http.Server.Request) !bool {
    if (request.head.method.requestHasBody() and request.head.transfer_encoding == .none and request.head.content_length == null) request.head.keep_alive = false;
    const route = route_registry.find(request.head.method, request.head.target) orelse {
        try request.respond("{\"detail\":\"Not Found\"}", .{
            .status = .not_found,
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        });
        return request.head.keep_alive;
    };

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
    if (mode == .head and std.mem.eql(u8, route.path, "/v1/models")) {
        const response = try worker_service.modelCatalogPayload(allocator, io, client, database);
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
        return try serveHeadChat(allocator, io, client, database, worker_pool, request);
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/v1/chat/completions")) {
        return try serveLocalChat(allocator, io, client, database, recipe_column, llm_instance_path, request, inference_origin);
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/v1/responses")) {
        return try serveLocalPassthrough(allocator, io, client, database, recipe_column, llm_instance_path, request, inference_origin, .responses);
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/v1/messages")) {
        return try serveLocalPassthrough(allocator, io, client, database, recipe_column, llm_instance_path, request, inference_origin, .messages);
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
        supervisor.launch(client, database, recipe_column, recipe_id, default_trust_remote_code, environment) catch |failure| {
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
        const response = try system_service.configPayload(allocator, io, configuration, system, supervisor, runtime_cache);
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
        try serveControllerEvents(allocator, io, client, database, recipe_column, configuration, default_trust_remote_code, system, supervisor, runtime_cache, request);
        return false;
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/compute/instances") and request.head.method == .GET) {
        const response = try supervisor.instancesPayload(client);
        defer allocator.free(response);
        try request.respond(response, .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return request.head.keep_alive;
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/compute/instances/:name/stop")) {
        const name = try pathParameterBetween(allocator, request.head.target, "/compute/instances/", "/stop");
        defer allocator.free(name);
        const stopped = supervisor.stopNamed(name) catch |failure| return try respondLifecycleFailure(request, failure);
        try request.respond(if (stopped) "{\"stopped\":true}" else "{\"stopped\":false}", .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return request.head.keep_alive;
    }
    if (mode != .head and std.mem.eql(u8, route.path, "/compute/instances/:name/cancel")) {
        const name = try pathParameterBetween(allocator, request.head.target, "/compute/instances/", "/cancel");
        defer allocator.free(name);
        const cancelled = try supervisor.cancelNamed(name);
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

fn serveHeadChat(allocator: std.mem.Allocator, io: Io, client: *http.Client, database: *sqlite.Database, worker_pool: *worker_service.Pool, request: *http.Server.Request) !bool {
    if (!worker_pool.tryAcquireInference()) {
        try request.respond("{\"detail\":\"Inference request capacity is exhausted\"}", .{
            .status = .service_unavailable,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        });
        return false;
    }
    defer worker_pool.releaseInference();
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

fn serveLocalChat(allocator: std.mem.Allocator, io: Io, client: *http.Client, database: *sqlite.Database, recipe_column: recipes.PayloadColumn, llm_instance_path: []const u8, request: *http.Server.Request, inference_origin: []const u8) !bool {
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

fn serveLocalPassthrough(allocator: std.mem.Allocator, io: Io, client: *http.Client, database: *sqlite.Database, recipe_column: recipes.PayloadColumn, llm_instance_path: []const u8, request: *http.Server.Request, inference_origin: []const u8, protocol: LocalProtocol) !bool {
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

fn serveControllerEvents(allocator: std.mem.Allocator, io: Io, client: *http.Client, database: *sqlite.Database, recipe_column: recipes.PayloadColumn, configuration: *const Config, default_trust_remote_code: bool, system: *const system_info.Snapshot, supervisor: *lifecycle.Supervisor, runtime_cache: *runtime_info.Cache, request: *http.Server.Request) !void {
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
            const runtime = try system_service.runtimeSummaryPayload(allocator, io, configuration, system, supervisor, runtime_cache, database, recipe_column, default_trust_remote_code);
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
