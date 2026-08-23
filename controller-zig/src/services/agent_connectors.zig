const std = @import("std");
const config = @import("../config.zig");
const repository = @import("../repository/agent_connectors.zig");
const sqlite = @import("../repository/sqlite.zig");
const harness_nodes = @import("harness_nodes.zig");
const node_transport = @import("node_transport.zig");

const Io = std.Io;
const http = std.http;
const mask = "••••••••";

pub fn listPayload(allocator: std.mem.Allocator, io: Io, mode: config.Mode, client: *http.Client, database: *sqlite.Database, preferred_node: ?[]const u8) ![]u8 {
    if (mode == .standalone) return listLocal(allocator, io, database);
    var target = (try harness_nodes.selectCapability(allocator, io, database, "mcp", preferred_node)) orelse return error.ConnectorNodeRequired;
    defer target.deinit();
    return node_transport.get(allocator, client, &target, "/internal/node/v1/connectors") catch |failure| switch (failure) {
        error.NodeUnavailable => error.ConnectorNodeUnavailable,
        else => failure,
    };
}

pub fn upsertPayload(allocator: std.mem.Allocator, io: Io, mode: config.Mode, client: *http.Client, database: *sqlite.Database, preferred_node: ?[]const u8, document: []const u8) ![]u8 {
    if (mode == .standalone) return upsertLocal(allocator, io, database, document);
    var target = (try harness_nodes.selectCapability(allocator, io, database, "mcp", preferred_node)) orelse return error.ConnectorNodeRequired;
    defer target.deinit();
    return node_transport.send(allocator, client, &target, "/internal/node/v1/connectors", .POST, document) catch |failure| switch (failure) {
        error.NodeRequestRejected => error.ConnectorNodeRejected,
        else => failure,
    };
}

pub fn deletePayload(allocator: std.mem.Allocator, io: Io, mode: config.Mode, client: *http.Client, database: *sqlite.Database, preferred_node: ?[]const u8, id: []const u8) ![]u8 {
    if (!validId(id)) return error.InvalidConnectorId;
    if (mode == .standalone) return deleteLocal(allocator, io, database, id);
    var target = (try harness_nodes.selectCapability(allocator, io, database, "mcp", preferred_node)) orelse return error.ConnectorNodeRequired;
    defer target.deinit();
    const path = try std.fmt.allocPrint(allocator, "/internal/node/v1/connectors?id={s}", .{id});
    defer allocator.free(path);
    return node_transport.send(allocator, client, &target, path, .DELETE, null) catch |failure| switch (failure) {
        error.NodeRequestRejected => error.ConnectorNodeRejected,
        else => failure,
    };
}

pub fn listLocal(allocator: std.mem.Allocator, io: Io, database: *sqlite.Database) ![]u8 {
    try database.lock(io);
    var connectors = repository.list(allocator, database) catch |failure| {
        database.unlock(io);
        return failure;
    };
    database.unlock(io);
    defer connectors.deinit();
    var output: Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"connectors\":[");
    for (connectors.documents, 0..) |document, index| {
        if (index > 0) try output.writer.writeByte(',');
        try writeView(allocator, &output.writer, document);
    }
    try output.writer.writeAll("]}");
    return output.toOwnedSlice();
}

pub fn upsertLocal(allocator: std.mem.Allocator, io: Io, database: *sqlite.Database, document: []const u8) ![]u8 {
    var incoming = std.json.parseFromSlice(std.json.Value, allocator, document, .{}) catch return error.InvalidConnectorPayload;
    defer incoming.deinit();
    if (incoming.value != .object) return error.InvalidConnectorPayload;
    const object = &incoming.value.object;
    const id = stringField(object.*, "id") orelse return error.ConnectorIdRequired;
    if (!validId(id)) return error.InvalidConnectorId;
    const transport = stringField(object.*, "transport") orelse return error.ConnectorTransportRequired;
    if (!std.mem.eql(u8, transport, "stdio") and !std.mem.eql(u8, transport, "http")) return error.InvalidConnectorTransport;
    if (std.mem.eql(u8, transport, "stdio") and stringField(object.*, "command") == null) return error.ConnectorCommandRequired;
    if (std.mem.eql(u8, transport, "http")) {
        const url = stringField(object.*, "url") orelse return error.ConnectorUrlRequired;
        const uri = std.Uri.parse(url) catch return error.InvalidConnectorUrl;
        if ((!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) or uri.host == null) return error.InvalidConnectorUrl;
    }
    try validateOptionalFields(object.*);
    try database.lock(io);
    defer database.unlock(io);
    var connectors = try repository.list(allocator, database);
    defer connectors.deinit();
    for (connectors.documents) |stored_document| {
        var candidate = std.json.parseFromSlice(std.json.Value, allocator, stored_document, .{}) catch continue;
        defer candidate.deinit();
        if (candidate.value != .object) continue;
        const candidate_id = stringField(candidate.value.object, "id") orelse continue;
        if (!std.mem.eql(u8, candidate_id, id) and samePrefix(candidate_id, id)) return error.ConnectorNamespaceCollision;
    }
    const stored_document = try repository.get(allocator, database, id);
    defer if (stored_document) |value| allocator.free(value);
    var stored = if (stored_document) |value| try std.json.parseFromSlice(std.json.Value, allocator, value, .{}) else null;
    defer if (stored) |*value| value.deinit();
    if (stored) |*value| if (value.value == .object) {
        try preserveFields(incoming.arena.allocator(), object, value.value.object);
        restoreSecrets(object, value.value.object, "env", "envSecret");
        restoreSecrets(object, value.value.object, "headers", "headerSecret");
    };
    const arena = incoming.arena.allocator();
    const name = stringField(object.*, "name") orelse id;
    try object.put(arena, "name", .{ .string = try arena.dupe(u8, name) });
    const enabled = booleanField(object.*, "enabled") orelse true;
    try object.put(arena, "enabled", .{ .bool = enabled });
    if (object.get("allowTools")) |allow_tools| {
        if (allow_tools == .array and allow_tools.array.items.len == 0) _ = object.orderedRemove("allowTools");
    }
    const stored_value = try stringify(allocator, incoming.value);
    defer allocator.free(stored_value);
    try repository.save(database, id, enabled, stored_value);
    return listLocked(allocator, database);
}

pub fn deleteLocal(allocator: std.mem.Allocator, io: Io, database: *sqlite.Database, id: []const u8) ![]u8 {
    if (!validId(id)) return error.InvalidConnectorId;
    try database.lock(io);
    defer database.unlock(io);
    try repository.delete(database, id);
    return listLocked(allocator, database);
}

fn listLocked(allocator: std.mem.Allocator, database: *sqlite.Database) ![]u8 {
    var connectors = try repository.list(allocator, database);
    defer connectors.deinit();
    var output: Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"connectors\":[");
    for (connectors.documents, 0..) |document, index| {
        if (index > 0) try output.writer.writeByte(',');
        try writeView(allocator, &output.writer, document);
    }
    try output.writer.writeAll("]}");
    return output.toOwnedSlice();
}

fn writeView(allocator: std.mem.Allocator, writer: *Io.Writer, document: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, document, .{}) catch return error.InvalidConnectorRecord;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidConnectorRecord;
    var secret_keys: std.json.Array = .init(parsed.arena.allocator());
    try maskRecord(parsed.arena.allocator(), &parsed.value.object, "env", "envSecret", &secret_keys);
    try maskRecord(parsed.arena.allocator(), &parsed.value.object, "headers", "headerSecret", &secret_keys);
    try parsed.value.object.put(parsed.arena.allocator(), "secret_keys", .{ .array = secret_keys });
    try std.json.Stringify.value(parsed.value, .{}, writer);
}

fn maskRecord(allocator: std.mem.Allocator, object: *std.json.ObjectMap, record_name: []const u8, flags_name: []const u8, secret_keys: *std.json.Array) !void {
    const record = object.getPtr(record_name) orelse return;
    if (record.* != .object) return;
    var iterator = record.object.iterator();
    while (iterator.next()) |entry| {
        if (!secretKey(object.*, flags_name, entry.key_ptr.*) or entry.value_ptr.* != .string or entry.value_ptr.string.len == 0) continue;
        entry.value_ptr.* = .{ .string = mask };
        try secret_keys.append(.{ .string = try allocator.dupe(u8, entry.key_ptr.*) });
    }
}

fn restoreSecrets(incoming: *std.json.ObjectMap, stored: std.json.ObjectMap, record_name: []const u8, flags_name: []const u8) void {
    const record = incoming.getPtr(record_name) orelse return;
    if (record.* != .object) return;
    const stored_record = stored.get(record_name) orelse return;
    if (stored_record != .object) return;
    var iterator = record.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .string or !std.mem.eql(u8, entry.value_ptr.string, mask)) continue;
        if (!secretKey(stored, flags_name, entry.key_ptr.*)) continue;
        const previous = stored_record.object.get(entry.key_ptr.*) orelse continue;
        if (previous == .string and previous.string.len > 0) entry.value_ptr.* = previous;
    }
}

fn preserveFields(allocator: std.mem.Allocator, incoming: *std.json.ObjectMap, stored: std.json.ObjectMap) !void {
    for ([_][]const u8{ "envSecret", "headerSecret", "cwd", "allowTools", "origin", "auth" }) |name| {
        if (incoming.get(name) == null) if (stored.get(name)) |value| try incoming.put(allocator, name, value);
    }
}

fn validateOptionalFields(object: std.json.ObjectMap) !void {
    for ([_][]const u8{ "args", "allowTools" }) |name| if (object.get(name)) |value| {
        if (value != .array or value.array.items.len > 1000) return error.InvalidConnectorPayload;
        for (value.array.items) |entry| if (entry != .string or entry.string.len > 4096) return error.InvalidConnectorPayload;
    };
    for ([_][]const u8{ "env", "headers" }) |name| if (object.get(name)) |value| {
        if (value != .object or value.object.count() > 256) return error.InvalidConnectorPayload;
        var iterator = value.object.iterator();
        while (iterator.next()) |entry| if (entry.key_ptr.len > 256 or entry.value_ptr.* != .string or entry.value_ptr.string.len > 64 * 1024) return error.InvalidConnectorPayload;
    };
    for ([_][]const u8{ "envSecret", "headerSecret" }) |name| if (object.get(name)) |value| {
        if (value != .object or value.object.count() > 256) return error.InvalidConnectorPayload;
        var iterator = value.object.iterator();
        while (iterator.next()) |entry| if (entry.value_ptr.* != .bool) return error.InvalidConnectorPayload;
    };
    if (object.get("enabled")) |value| if (value != .bool) return error.InvalidConnectorPayload;
}

fn secretKey(object: std.json.ObjectMap, flags_name: []const u8, key: []const u8) bool {
    if (object.get(flags_name)) |flags| if (flags == .object) if (flags.object.get(key)) |flag| if (flag == .bool) return flag.bool;
    for ([_][]const u8{ "token", "key", "secret", "password", "auth" }) |needle| if (containsIgnoreCase(key, needle)) return true;
    return false;
}

fn containsIgnoreCase(value: []const u8, needle: []const u8) bool {
    if (needle.len > value.len) return false;
    var index: usize = 0;
    while (index + needle.len <= value.len) : (index += 1) if (std.ascii.eqlIgnoreCase(value[index .. index + needle.len], needle)) return true;
    return false;
}

fn samePrefix(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if ((if (a == '-') '_' else a) != (if (b == '-') '_' else b)) return false;
    return true;
}

fn validId(value: []const u8) bool {
    if (value.len == 0 or value.len > 64 or !std.ascii.isLower(value[0]) and !std.ascii.isDigit(value[0])) return false;
    for (value) |character| if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '-' and character != '_') return false;
    return true;
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    if (value != .string) return null;
    const trimmed = std.mem.trim(u8, value.string, " \t\r\n");
    return if (trimmed.len == 0) null else trimmed;
}

fn booleanField(object: std.json.ObjectMap, name: []const u8) ?bool {
    const value = object.get(name) orelse return null;
    return if (value == .bool) value.bool else null;
}

fn stringify(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var output: Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try std.json.Stringify.value(value, .{}, &output.writer);
    return output.toOwnedSlice();
}
