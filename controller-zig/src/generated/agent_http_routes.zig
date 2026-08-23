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
    .{ .method = .GET, .path = "/api/agent/head-connection", .ownership = .worker, .streaming = .never },
    .{ .method = .PUT, .path = "/api/agent/head-connection", .ownership = .worker, .streaming = .never },
    .{ .method = .DELETE, .path = "/api/agent/head-connection", .ownership = .worker, .streaming = .never },
    .{ .method = .POST, .path = "/api/agent/enrollments", .ownership = .head, .streaming = .never },
    .{ .method = .DELETE, .path = "/api/agent/enrollments/:id", .ownership = .head, .streaming = .never },
    .{ .method = .GET, .path = "/api/agent/automations", .ownership = .head, .streaming = .never },
    .{ .method = .POST, .path = "/api/agent/automations", .ownership = .head, .streaming = .never },
    .{ .method = .PATCH, .path = "/api/agent/automations/:id", .ownership = .head, .streaming = .never },
    .{ .method = .DELETE, .path = "/api/agent/automations/:id", .ownership = .head, .streaming = .never },
    .{ .method = .POST, .path = "/api/agent/automations/:id/run", .ownership = .head, .streaming = .never },
    .{ .method = .POST, .path = "/internal/harness/v1/turn", .ownership = .worker, .streaming = .never },
    .{ .method = .POST, .path = "/internal/harness/v1/abort", .ownership = .worker, .streaming = .never },
    .{ .method = .POST, .path = "/internal/harness/v1/compact", .ownership = .worker, .streaming = .never },
    .{ .method = .POST, .path = "/internal/harness/v1/extension-ui", .ownership = .worker, .streaming = .never },
    .{ .method = .GET, .path = "/internal/harness/v1/sessions", .ownership = .worker, .streaming = .never },
    .{ .method = .GET, .path = "/internal/harness/v1/status", .ownership = .worker, .streaming = .never },
    .{ .method = .GET, .path = "/internal/harness/v1/events", .ownership = .worker, .streaming = .always },
    .{ .method = .GET, .path = "/internal/harness/v1/setup-checks", .ownership = .worker, .streaming = .never },
};

comptime {
    _ = std.http.Method;
}
