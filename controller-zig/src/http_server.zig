const std = @import("std");
const config_module = @import("config.zig");
const shutdown = @import("shutdown.zig");

const Config = config_module.Config;
const Mode = config_module.Mode;
const Io = std.Io;
const net = Io.net;
const http = std.http;

const Ownership = enum {
    head,
    worker,
    shared,
    proxied,
};

const Route = struct {
    method: http.Method,
    path: []const u8,
    ownership: Ownership,
};

const routes = [_]Route{
    .{ .method = .GET, .path = "/health", .ownership = .shared },
    .{ .method = .GET, .path = "/__zig-spike/sse", .ownership = .shared },
};

pub const HttpServer = struct {
    io: Io,
    config: Config,
    listener: net.Server,

    pub fn init(io: Io, config: Config) !HttpServer {
        const address = try net.IpAddress.parse(config.host, config.port);
        return .{
            .io = io,
            .config = config,
            .listener = try address.listen(io, .{ .reuse_address = true }),
        };
    }

    pub fn deinit(server: *HttpServer) void {
        server.listener.deinit(server.io);
    }

    pub fn run(server: *HttpServer) !void {
        var group: Io.Group = .init;
        defer group.cancel(server.io);
        while (!shutdown.isRequested()) {
            var stream = server.listener.accept(server.io) catch |failure| {
                if (shutdown.isRequested()) return;
                return failure;
            };
            group.concurrent(server.io, serveConnection, .{ server.io, server.config.mode, stream }) catch {
                stream.close(server.io);
            };
        }
    }
};

fn serveConnection(io: Io, mode: Mode, stream: net.Stream) void {
    defer {
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
        const keep_connection = serveRequest(io, mode, &request) catch return;
        if (!keep_connection) return;
    }
}

fn writeProtocolError(writer: *Io.Writer, status: []const u8) void {
    writer.print("HTTP/1.1 {s}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n", .{status}) catch return;
    writer.flush() catch return;
}

fn serveRequest(io: Io, mode: Mode, request: *http.Server.Request) !bool {
    const route = findRoute(request.head.method, request.head.target) orelse {
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

    try serveSse(io, request);
    return false;
}

fn ownershipAllows(ownership: Ownership, mode: Mode) bool {
    return switch (ownership) {
        .shared => true,
        .head => mode != .worker,
        .worker => mode != .head,
        .proxied => true,
    };
}

fn findRoute(method: http.Method, target: []const u8) ?Route {
    const path_end = std.mem.findScalar(u8, target, '?') orelse target.len;
    const path = target[0..path_end];
    for (routes) |route| {
        if (route.method == method and std.mem.eql(u8, route.path, path)) return route;
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
