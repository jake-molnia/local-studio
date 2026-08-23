const std = @import("std");

pub const ProcessReference = struct {
    pid: i32,
    process_group_id: ?i32,
    session_id: ?i32,
    start_token: ?[]u8,
};

pub const Record = struct {
    allocator: std.mem.Allocator,
    recipe_id: []u8,
    engine: []u8,
    port: u16,
    nonce: []u8,
    process: ?ProcessReference,

    pub fn deinit(record: *Record) void {
        record.allocator.free(record.recipe_id);
        record.allocator.free(record.engine);
        record.allocator.free(record.nonce);
        if (record.process) |reference| {
            if (reference.start_token) |token| record.allocator.free(token);
        }
        record.* = undefined;
    }
};

pub fn readLlm(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?Record {
    const document = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |failure| switch (failure) {
        error.FileNotFound => return null,
        else => return failure,
    };
    defer allocator.free(document);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, document, .{}) catch return error.InvalidInstanceRecord;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidInstanceRecord;
    const object = parsed.value.object;
    const name = stringField(object, "name") orelse return error.InvalidInstanceRecord;
    if (!std.mem.eql(u8, name, "llm")) return error.InvalidInstanceRecord;
    const recipe_id = stringField(object, "recipeId") orelse return error.InvalidInstanceRecord;
    const engine = stringField(object, "engine") orelse return error.InvalidInstanceRecord;
    const nonce = stringField(object, "nonce") orelse return error.InvalidInstanceRecord;
    const port = positiveU16(object.get("port")) orelse return error.InvalidInstanceRecord;

    const owned_recipe_id = try allocator.dupe(u8, recipe_id);
    errdefer allocator.free(owned_recipe_id);
    const owned_engine = try allocator.dupe(u8, engine);
    errdefer allocator.free(owned_engine);
    const owned_nonce = try allocator.dupe(u8, nonce);
    errdefer allocator.free(owned_nonce);
    const process = try parseProcessReference(allocator, object.get("ref"));
    errdefer if (process) |reference| if (reference.start_token) |token| allocator.free(token);
    return .{
        .allocator = allocator,
        .recipe_id = owned_recipe_id,
        .engine = owned_engine,
        .port = port,
        .nonce = owned_nonce,
        .process = process,
    };
}

fn parseProcessReference(allocator: std.mem.Allocator, value: ?std.json.Value) !?ProcessReference {
    const present = value orelse return null;
    if (present == .null) return null;
    if (present != .object) return error.InvalidInstanceRecord;
    const kind = stringField(present.object, "kind") orelse return error.InvalidInstanceRecord;
    if (!std.mem.eql(u8, kind, "process")) return null;
    const pid = positiveI32(present.object.get("pid")) orelse return error.InvalidInstanceRecord;
    const process_group_id = nullablePositiveI32(present.object.get("processGroupId")) orelse return error.InvalidInstanceRecord;
    const session_id = nullablePositiveI32(present.object.get("sessionId")) orelse return error.InvalidInstanceRecord;
    const token_value = present.object.get("startToken");
    const start_token = if (token_value == null or token_value.? == .null)
        null
    else if (token_value.? == .string and token_value.?.string.len > 0)
        try allocator.dupe(u8, token_value.?.string)
    else
        return error.InvalidInstanceRecord;
    return .{
        .pid = pid,
        .process_group_id = process_group_id.value,
        .session_id = session_id.value,
        .start_token = start_token,
    };
}

const NullableI32 = struct { value: ?i32 };

fn nullablePositiveI32(value: ?std.json.Value) ?NullableI32 {
    const present = value orelse return null;
    if (present == .null) return .{ .value = null };
    return .{ .value = positiveI32(present) orelse return null };
}

fn positiveI32(value: ?std.json.Value) ?i32 {
    const present = value orelse return null;
    if (present != .integer or present.integer <= 0 or present.integer > std.math.maxInt(i32)) return null;
    return @intCast(present.integer);
}

fn positiveU16(value: ?std.json.Value) ?u16 {
    const present = value orelse return null;
    if (present != .integer or present.integer <= 0 or present.integer > std.math.maxInt(u16)) return null;
    return @intCast(present.integer);
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}
