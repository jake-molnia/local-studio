const std = @import("std");
const http_routes = @import("http_routes.zig");

pub const routes = [_]http_routes.Route{
    .{ .method = .POST, .path = "/api/agent/turn", .ownership = .head, .streaming = .never },
    .{ .method = .POST, .path = "/api/agent/abort", .ownership = .head, .streaming = .never },
    .{ .method = .POST, .path = "/api/agent/compact", .ownership = .head, .streaming = .never },
    .{ .method = .POST, .path = "/api/agent/runtime/extension-ui", .ownership = .head, .streaming = .never },
    .{ .method = .GET, .path = "/api/agent/runtime/sessions", .ownership = .head, .streaming = .never },
    .{ .method = .GET, .path = "/api/agent/runtime/status", .ownership = .head, .streaming = .never },
    .{ .method = .GET, .path = "/api/agent/runtime/events", .ownership = .head, .streaming = .always },
    .{ .method = .GET, .path = "/api/agent/setup-checks", .ownership = .head, .streaming = .never },
};

comptime {
    _ = std.http.Method;
}
