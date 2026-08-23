const std = @import("std");
const config_module = @import("config.zig");
const shutdown = @import("shutdown.zig");
const reverse_proxy = @import("reverse_proxy.zig");
const route_registry = @import("route_registry.zig");
const rig_service = @import("services/rigs.zig");
const worker_service = @import("services/workers.zig");
const model_service = @import("services/models.zig");
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

    pub fn run(server: *HttpServer, database: *sqlite.Database, recipe_column: recipes.PayloadColumn, system: *const system_info.Snapshot, worker_pool: *worker_service.Pool) !void {
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
            group.concurrent(server.io, serveConnection, .{ server.allocator, server.io, server.config.mode, &server.client, database, recipe_column, server.config.llm_instance_path, system, worker_pool, server.config.spike_upstream, server.config.spike_fallback_upstream, &server.connection_limiter, stream }) catch {
                server.connection_limiter.release();
                stream.close(server.io);
            };
        }
    }
};

fn serveConnection(allocator: std.mem.Allocator, io: Io, mode: Mode, client: *http.Client, database: *sqlite.Database, recipe_column: recipes.PayloadColumn, llm_instance_path: []const u8, system: *const system_info.Snapshot, worker_pool: *worker_service.Pool, spike_upstream: ?[]const u8, spike_fallback_upstream: ?[]const u8, connection_limiter: *ConnectionLimiter, stream: net.Stream) void {
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
        const keep_connection = serveRequest(allocator, io, mode, client, database, recipe_column, llm_instance_path, system, worker_pool, spike_upstream, spike_fallback_upstream, &request) catch return;
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

fn serveRequest(allocator: std.mem.Allocator, io: Io, mode: Mode, client: *http.Client, database: *sqlite.Database, recipe_column: recipes.PayloadColumn, llm_instance_path: []const u8, system: *const system_info.Snapshot, worker_pool: *worker_service.Pool, spike_upstream: ?[]const u8, spike_fallback_upstream: ?[]const u8, request: *http.Server.Request) !bool {
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
        return try respondModelNotRunning(allocator, request, model_id);
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

fn respondModelRequired(request: *http.Server.Request) !bool {
    try request.respond("{\"detail\":\"model is required\"}", .{
        .status = .bad_request,
        .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
    });
    return request.head.keep_alive;
}

fn respondModelNotRunning(allocator: std.mem.Allocator, request: *http.Server.Request, model_id: []const u8) !bool {
    const message = try std.fmt.allocPrint(allocator, "No model is running. Launch {s} from the frontend before sending requests.", .{model_id});
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
