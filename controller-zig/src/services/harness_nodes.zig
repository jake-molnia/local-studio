const std = @import("std");
const credentials = @import("../repository/rig_node_credentials.zig");
const rigs = @import("../repository/rigs.zig");
const sqlite = @import("../repository/sqlite.zig");

const Io = std.Io;

pub const Target = struct {
    allocator: std.mem.Allocator,
    id: []u8,
    name: []u8,
    address: []u8,
    api_key: []u8,

    pub fn deinit(target: *Target) void {
        target.allocator.free(target.id);
        target.allocator.free(target.name);
        target.allocator.free(target.address);
        target.allocator.free(target.api_key);
        target.* = undefined;
    }
};

pub fn select(allocator: std.mem.Allocator, io: Io, database: *sqlite.Database, harness: []const u8, preferred_node_id: ?[]const u8) !?Target {
    try database.lock(io);
    defer database.unlock(io);
    var documents = try rigs.list(allocator, database);
    defer documents.deinit();
    var fallback: ?Target = null;
    errdefer if (fallback) |*target| target.deinit();
    for (documents.items()) |document| {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, document, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const nodes = parsed.value.object.get("nodes") orelse continue;
        if (nodes != .array) continue;
        for (nodes.array.items) |node| {
            if (!supportsHarness(node, harness)) continue;
            const id = stringField(node.object, "id") orelse continue;
            if (std.mem.eql(u8, id, "local")) continue;
            const address = nullableStringField(node.object, "address") orelse continue;
            const name = stringField(node.object, "name") orelse id;
            var target = try makeTarget(allocator, database, id, name, address);
            if (preferred_node_id) |preferred| {
                if (std.mem.eql(u8, preferred, id)) {
                    if (fallback) |*existing| existing.deinit();
                    return target;
                }
                target.deinit();
                continue;
            }
            if (fallback == null) fallback = target else target.deinit();
        }
    }
    return fallback;
}

pub fn count(allocator: std.mem.Allocator, io: Io, database: *sqlite.Database, harness: []const u8) !usize {
    try database.lock(io);
    defer database.unlock(io);
    var documents = try rigs.list(allocator, database);
    defer documents.deinit();
    var total: usize = 0;
    for (documents.items()) |document| {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, document, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const nodes = parsed.value.object.get("nodes") orelse continue;
        if (nodes != .array) continue;
        for (nodes.array.items) |node| {
            if (!supportsHarness(node, harness)) continue;
            const id = stringField(node.object, "id") orelse continue;
            if (std.mem.eql(u8, id, "local")) continue;
            if (nullableStringField(node.object, "address") != null) total += 1;
        }
    }
    return total;
}

fn supportsHarness(node: std.json.Value, harness: []const u8) bool {
    if (node != .object) return false;
    const capabilities = node.object.get("capabilities") orelse return false;
    if (capabilities != .object) return false;
    const configured = capabilities.object.get("harnesses") orelse return false;
    if (configured != .array) return false;
    for (configured.array.items) |entry| {
        if (entry == .string and std.mem.eql(u8, entry.string, harness)) return true;
    }
    return false;
}

fn makeTarget(allocator: std.mem.Allocator, database: *sqlite.Database, id: []const u8, name: []const u8, address: []const u8) !Target {
    const owned_id = try allocator.dupe(u8, id);
    errdefer allocator.free(owned_id);
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    const normalized_address = try normalizeAddress(allocator, address);
    errdefer allocator.free(normalized_address);
    return .{
        .allocator = allocator,
        .id = owned_id,
        .name = owned_name,
        .address = normalized_address,
        .api_key = try credentials.get(allocator, database, id),
    };
}

fn normalizeAddress(allocator: std.mem.Allocator, address: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, address, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidHarnessAddress;
    const candidate = if (std.ascii.startsWithIgnoreCase(trimmed, "http://") or std.ascii.startsWithIgnoreCase(trimmed, "https://"))
        try allocator.dupe(u8, trimmed)
    else
        try std.fmt.allocPrint(allocator, "http://{s}", .{trimmed});
    defer allocator.free(candidate);
    const uri = std.Uri.parse(candidate) catch return error.InvalidHarnessAddress;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.InvalidHarnessAddress;
    const host = uri.host orelse return error.InvalidHarnessAddress;
    var output: Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const scheme = if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) "https" else "http";
    try output.writer.print("{s}://", .{scheme});
    try host.formatHost(&output.writer);
    if (uri.port) |port| {
        if ((std.mem.eql(u8, scheme, "http") and port != 80) or (std.mem.eql(u8, scheme, "https") and port != 443)) {
            try output.writer.print(":{d}", .{port});
        }
    }
    return try output.toOwnedSlice();
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    if (value != .string) return null;
    const trimmed = std.mem.trim(u8, value.string, " \t\r\n");
    return if (trimmed.len > 0) trimmed else null;
}

fn nullableStringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    if (value == .null) return null;
    if (value != .string) return null;
    const trimmed = std.mem.trim(u8, value.string, " \t\r\n");
    return if (trimmed.len > 0) trimmed else null;
}
