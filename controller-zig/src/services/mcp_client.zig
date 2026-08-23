const std = @import("std");

const Io = std.Io;
const max_frame_bytes = 4 * 1024 * 1024;

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
