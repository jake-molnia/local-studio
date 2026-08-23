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

pub fn writeProcess(io: std.Io, path: []const u8, recipe_id: []const u8, engine: []const u8, port: u16, nonce: []const u8, reference: ProcessReference, ready_timeout_seconds: u64) !void {
    var timestamp_buffer: [24]u8 = undefined;
    const started_at = formatTimestamp(io, &timestamp_buffer);
    var deadline_buffer: [24]u8 = undefined;
    const ready_deadline_at = formatTimestampAt(io, ready_timeout_seconds, &deadline_buffer);
    const Reference = struct {
        kind: []const u8 = "process",
        pid: i32,
        processGroupId: ?i32,
        sessionId: ?i32,
        startToken: ?[]const u8,
    };
    const Document = struct {
        name: []const u8 = "llm",
        nodeId: []const u8 = "self",
        engine: []const u8,
        recipeId: []const u8,
        runtime: []const u8 = "process",
        ref: Reference,
        port: u16,
        devices: []const []const u8 = &.{},
        nonce: []const u8,
        startedAt: []const u8,
        readyDeadlineAt: []const u8,
    };
    var output: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer output.deinit();
    try std.json.Stringify.value(Document{
        .engine = engine,
        .recipeId = recipe_id,
        .ref = .{
            .pid = reference.pid,
            .processGroupId = reference.process_group_id,
            .sessionId = reference.session_id,
            .startToken = reference.start_token,
        },
        .port = port,
        .nonce = nonce,
        .startedAt = started_at,
        .readyDeadlineAt = ready_deadline_at,
    }, .{ .whitespace = .indent_2 }, &output.writer);
    var atomic_file = try std.Io.Dir.cwd().createFileAtomic(io, path, .{
        .permissions = @enumFromInt(0o600),
        .make_path = true,
        .replace = true,
    });
    defer atomic_file.deinit(io);
    try atomic_file.file.writeStreamingAll(io, output.writer.buffered());
    try atomic_file.file.sync(io);
    try atomic_file.replace(io);
}

pub fn dropLlm(io: std.Io, path: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(io, path) catch |failure| switch (failure) {
        error.FileNotFound => {},
        else => return failure,
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

fn formatTimestamp(io: std.Io, buffer: *[24]u8) []const u8 {
    return formatTimestampAt(io, 0, buffer);
}

fn formatTimestampAt(io: std.Io, offset_seconds: u64, buffer: *[24]u8) []const u8 {
    const seconds = std.Io.Clock.real.now(io).toSeconds();
    const now: u64 = @intCast(@max(seconds, 0));
    const epoch = std.time.epoch.EpochSeconds{ .secs = now +| offset_seconds };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.000Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    }) catch unreachable;
}
