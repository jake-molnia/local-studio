const std = @import("std");

const Io = std.Io;
const max_frame_bytes = 4 * 1024 * 1024;
const http = std.http;

pub const Operation = union(enum) {
    tools,
    call: struct {
        name: []const u8,
        arguments: std.json.Value,
    },
};

pub fn executeStdio(allocator: std.mem.Allocator, io: Io, environment: *const std.process.Environ.Map, connector: std.json.ObjectMap, operation: Operation) ![]u8 {
    const command = stringField(connector, "command") orelse return error.ConnectorCommandRequired;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, command);
    if (connector.get("args")) |args| {
        if (args != .array) return error.InvalidConnectorRecord;
        for (args.array.items) |argument| {
            if (argument != .string) return error.InvalidConnectorRecord;
            try argv.append(allocator, argument.string);
        }
    }
    var child_environment = try minimalEnvironment(allocator, environment, connector);
    defer child_environment.deinit();
    const cwd = stringField(connector, "cwd");
    if (cwd) |value| if (!std.fs.path.isAbsolute(value)) return error.ConnectorCwdMustBeAbsolute;
    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .environ_map = &child_environment,
        .cwd = if (cwd) |value| .{ .path = value } else .inherit,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
        .pgid = 0,
    });
    defer child.kill(io);
    var connection = Connection{ .allocator = allocator, .io = io, .child = &child };
    defer connection.deinit();
    const initialized = try connection.request(1,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"local-studio\",\"version\":\"2.1.0\"}}}",
    );
    allocator.free(initialized);
    try connection.send("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}");
    switch (operation) {
        .tools => return connection.request(2, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}"),
        .call => |call| {
            var request: Io.Writer.Allocating = .init(allocator);
            defer request.deinit();
            try request.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":");
            try std.json.Stringify.value(call.name, .{}, &request.writer);
            try request.writer.writeAll(",\"arguments\":");
            try std.json.Stringify.value(call.arguments, .{}, &request.writer);
            try request.writer.writeAll("}}");
            return connection.request(3, request.writer.buffered());
        },
    }
}

pub fn executeHttp(allocator: std.mem.Allocator, io: Io, client: *http.Client, connector: std.json.ObjectMap, operation: Operation) ![]u8 {
    const url = stringField(connector, "url") orelse return error.ConnectorUrlRequired;
    var initialized = try postHttp(allocator, io, client, connector, url, null,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"local-studio\",\"version\":\"2.1.0\"}}}",
    );
    defer initialized.deinit();
    const initialized_result = try rpcResult(allocator, initialized.body, 1);
    allocator.free(initialized_result);
    var notification = try postHttp(allocator, io, client, connector, url, initialized.session_id, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}");
    notification.deinit();
    switch (operation) {
        .tools => {
            var response = try postHttp(allocator, io, client, connector, url, initialized.session_id, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}");
            defer response.deinit();
            return rpcResult(allocator, response.body, 2);
        },
        .call => |call| {
            var request: Io.Writer.Allocating = .init(allocator);
            defer request.deinit();
            try request.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":");
            try std.json.Stringify.value(call.name, .{}, &request.writer);
            try request.writer.writeAll(",\"arguments\":");
            try std.json.Stringify.value(call.arguments, .{}, &request.writer);
            try request.writer.writeAll("}}");
            var response = try postHttp(allocator, io, client, connector, url, initialized.session_id, request.writer.buffered());
            defer response.deinit();
            return rpcResult(allocator, response.body, 3);
        },
    }
}

const HttpResponse = struct {
    allocator: std.mem.Allocator,
    body: []u8,
    session_id: ?[]u8,

    fn deinit(response: *HttpResponse) void {
        response.allocator.free(response.body);
        if (response.session_id) |value| response.allocator.free(value);
        response.* = undefined;
    }
};

fn postHttp(allocator: std.mem.Allocator, _: Io, client: *http.Client, connector: std.json.ObjectMap, url: []const u8, session_id: ?[]const u8, document: []const u8) !HttpResponse {
    if (document.len > max_frame_bytes) return error.McpFrameTooLarge;
    const uri = std.Uri.parse(url) catch return error.InvalidConnectorUrl;
    var headers: [260]http.Header = undefined;
    var count: usize = 0;
    headers[count] = .{ .name = "Content-Type", .value = "application/json" };
    count += 1;
    headers[count] = .{ .name = "Accept", .value = "application/json, text/event-stream" };
    count += 1;
    headers[count] = .{ .name = "MCP-Protocol-Version", .value = "2025-06-18" };
    count += 1;
    if (session_id) |value| {
        headers[count] = .{ .name = "Mcp-Session-Id", .value = value };
        count += 1;
    }
    if (connector.get("headers")) |configured| {
        if (configured != .object) return error.InvalidConnectorRecord;
        var iterator = configured.object.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.* != .string) return error.InvalidConnectorRecord;
            if (reservedHeader(entry.key_ptr.*)) continue;
            if (count == headers.len) return error.TooManyConnectorHeaders;
            headers[count] = .{ .name = entry.key_ptr.*, .value = entry.value_ptr.string };
            count += 1;
        }
    }
    var request = try client.request(.POST, uri, .{
        .redirect_behavior = .unhandled,
        .keep_alive = false,
        .headers = .{ .authorization = .omit, .user_agent = .omit, .connection = .omit, .accept_encoding = .omit, .content_type = .omit },
        .extra_headers = headers[0..count],
    });
    defer request.deinit();
    request.transfer_encoding = .{ .content_length = document.len };
    var write_buffer: [16 * 1024]u8 = undefined;
    var request_body = try request.sendBody(&write_buffer);
    try request_body.writer.writeAll(document);
    try request_body.end();
    var redirect_buffer: [16 * 1024]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);
    const code = @intFromEnum(response.head.status);
    if (code < 200 or code >= 300) return error.McpHttpRejected;
    const owned_session_id = try responseSessionId(allocator, response.head);
    errdefer if (owned_session_id) |value| allocator.free(value);
    const storage = try allocator.alloc(u8, max_frame_bytes);
    defer allocator.free(storage);
    var output: Io.Writer = .fixed(storage);
    var read_buffer: [16 * 1024]u8 = undefined;
    const reader = response.reader(&read_buffer);
    _ = reader.streamRemaining(&output) catch return error.McpFrameTooLarge;
    return .{ .allocator = allocator, .body = try allocator.dupe(u8, output.buffered()), .session_id = owned_session_id };
}

fn responseSessionId(allocator: std.mem.Allocator, head: http.Client.Response.Head) !?[]u8 {
    var iterator = head.iterateHeaders();
    while (iterator.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "mcp-session-id")) continue;
        const value = std.mem.trim(u8, header.value, " \t\r\n");
        if (value.len == 0 or value.len > 1024) return error.InvalidMcpSessionId;
        return @as(?[]u8, try allocator.dupe(u8, value));
    }
    return null;
}

fn rpcResult(allocator: std.mem.Allocator, body: []const u8, id: i64) ![]u8 {
    const document = try rpcDocument(allocator, body, id);
    defer allocator.free(document);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, document, .{}) catch return error.InvalidMcpFrame;
    defer parsed.deinit();
    if (parsed.value != .object or !matchesId(parsed.value.object, id)) return error.InvalidMcpResponse;
    if (parsed.value.object.get("error") != null) return error.McpRequestRejected;
    const result = parsed.value.object.get("result") orelse return error.InvalidMcpResponse;
    var output: Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try std.json.Stringify.value(result, .{}, &output.writer);
    return output.toOwnedSlice();
}

fn rpcDocument(allocator: std.mem.Allocator, body: []const u8, id: i64) ![]u8 {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidMcpResponse;
    if (trimmed[0] == '{') return allocator.dupe(u8, trimmed);
    var lines = std.mem.splitScalar(u8, trimmed, '\n');
    while (lines.next()) |line_value| {
        const line = std.mem.trim(u8, line_value, " \t\r");
        if (!std.mem.startsWith(u8, line, "data:")) continue;
        const candidate = std.mem.trim(u8, line[5..], " \t");
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, candidate, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value == .object and matchesId(parsed.value.object, id)) return allocator.dupe(u8, candidate);
    }
    return error.InvalidMcpResponse;
}

fn reservedHeader(name: []const u8) bool {
    for ([_][]const u8{ "content-type", "accept", "content-length", "transfer-encoding", "connection", "host", "mcp-protocol-version", "mcp-session-id" }) |reserved| {
        if (std.ascii.eqlIgnoreCase(name, reserved)) return true;
    }
    return false;
}

fn minimalEnvironment(allocator: std.mem.Allocator, environment: *const std.process.Environ.Map, connector: std.json.ObjectMap) !std.process.Environ.Map {
    var result = std.process.Environ.Map.init(allocator);
    errdefer result.deinit();
    for ([_][]const u8{ "PATH", "HOME", "USER", "SHELL", "TMPDIR", "LANG", "LC_ALL", "TERM", "SYSTEMROOT", "SystemRoot", "COMSPEC", "APPDATA", "LOCALAPPDATA", "USERPROFILE", "TEMP", "TMP" }) |name| {
        if (environment.get(name)) |value| try result.put(name, value);
    }
    if (connector.get("env")) |values| {
        if (values != .object) return error.InvalidConnectorRecord;
        var iterator = values.object.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.* != .string) return error.InvalidConnectorRecord;
            try result.put(entry.key_ptr.*, entry.value_ptr.string);
        }
    }
    return result;
}

const Connection = struct {
    allocator: std.mem.Allocator,
    io: Io,
    child: *std.process.Child,
    pending: std.ArrayList(u8) = .empty,

    fn deinit(connection: *Connection) void {
        connection.pending.deinit(connection.allocator);
    }

    fn send(connection: *Connection, document: []const u8) !void {
        if (document.len > max_frame_bytes) return error.McpFrameTooLarge;
        try connection.child.stdin.?.writeStreamingAll(connection.io, document);
        try connection.child.stdin.?.writeStreamingAll(connection.io, "\n");
    }

    fn request(connection: *Connection, id: i64, document: []const u8) ![]u8 {
        try connection.send(document);
        while (true) {
            const line = try connection.nextLine();
            defer connection.allocator.free(line);
            var parsed = std.json.parseFromSlice(std.json.Value, connection.allocator, line, .{}) catch return error.InvalidMcpFrame;
            defer parsed.deinit();
            if (parsed.value != .object or !matchesId(parsed.value.object, id)) continue;
            if (parsed.value.object.get("error") != null) return error.McpRequestRejected;
            const result = parsed.value.object.get("result") orelse return error.InvalidMcpResponse;
            var output: Io.Writer.Allocating = .init(connection.allocator);
            errdefer output.deinit();
            try std.json.Stringify.value(result, .{}, &output.writer);
            return output.toOwnedSlice();
        }
    }

    fn nextLine(connection: *Connection) ![]u8 {
        while (true) {
            if (std.mem.findScalar(u8, connection.pending.items, '\n')) |newline| {
                const line = try connection.allocator.dupe(u8, std.mem.trim(u8, connection.pending.items[0..newline], " \t\r"));
                const remaining = connection.pending.items[newline + 1 ..];
                std.mem.copyForwards(u8, connection.pending.items[0..remaining.len], remaining);
                connection.pending.items.len = remaining.len;
                if (line.len == 0) {
                    connection.allocator.free(line);
                    continue;
                }
                return line;
            }
            var buffer: [64 * 1024]u8 = undefined;
            const count = connection.child.stdout.?.readStreaming(connection.io, &.{&buffer}) catch |failure| switch (failure) {
                error.EndOfStream => return error.McpTransportClosed,
                else => return failure,
            };
            if (count == 0) return error.McpTransportClosed;
            if (connection.pending.items.len + count > max_frame_bytes) return error.McpFrameTooLarge;
            try connection.pending.appendSlice(connection.allocator, buffer[0..count]);
        }
    }
};

fn matchesId(object: std.json.ObjectMap, expected: i64) bool {
    const value = object.get("id") orelse return false;
    return value == .integer and value.integer == expected;
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    if (value != .string) return null;
    const trimmed = std.mem.trim(u8, value.string, " \t\r\n");
    return if (trimmed.len == 0) null else trimmed;
}
