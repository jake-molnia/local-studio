const std = @import("std");
const config_module = @import("config.zig");
const shutdown = @import("shutdown.zig");
const reverse_proxy = @import("reverse_proxy.zig");
const route_registry = @import("route_registry.zig");

const Config = config_module.Config;
const Mode = config_module.Mode;
const Ownership = route_registry.Ownership;
const Io = std.Io;
const net = Io.net;
const http = std.http;
const max_connection_tasks = 256;

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
    io: Io,
    config: Config,
    listener: net.Server,
    client: http.Client,
    connection_limiter: ConnectionLimiter = .{},

    pub fn init(allocator: std.mem.Allocator, io: Io, config: Config) !HttpServer {
        const address = try net.IpAddress.parse(config.host, config.port);
        return .{
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

    pub fn run(server: *HttpServer) !void {
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
            group.concurrent(server.io, serveConnection, .{ server.io, server.config.mode, &server.client, server.config.spike_upstream, server.config.spike_fallback_upstream, &server.connection_limiter, stream }) catch {
                server.connection_limiter.release();
                stream.close(server.io);
            };
        }
    }
};

fn serveConnection(io: Io, mode: Mode, client: *http.Client, spike_upstream: ?[]const u8, spike_fallback_upstream: ?[]const u8, connection_limiter: *ConnectionLimiter, stream: net.Stream) void {
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
        const keep_connection = serveRequest(io, mode, client, spike_upstream, spike_fallback_upstream, &request) catch return;
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

fn serveRequest(io: Io, mode: Mode, client: *http.Client, spike_upstream: ?[]const u8, spike_fallback_upstream: ?[]const u8, request: *http.Server.Request) !bool {
    const route = route_registry.find(request.head.method, request.head.target) orelse {
        try request.respond("{\"detail\":\"Not Found\"}", .{
            .status = .not_found,
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        });
        return request.head.keep_alive;
    };

    if (!ownershipAllows(route.ownership, mode)) {
        try request.respond("{\"detail\":\"Not Found\"}", .{ .status = .not_found });
        return request.head.keep_alive;
    }

    if (std.mem.eql(u8, route.path, "/health")) {
        try request.respond("{\"status\":\"ok\"}", .{
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        });
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

fn ownershipAllows(ownership: Ownership, mode: Mode) bool {
    return switch (ownership) {
        .shared => true,
        .head => mode != .worker,
        .worker => mode != .head,
        .proxied => true,
    };
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
