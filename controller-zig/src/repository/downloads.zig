const std = @import("std");
const sqlite = @import("sqlite.zig");

const max_record_bytes = 8 * 1024 * 1024;
const max_files = 100_000;

pub fn initialize(database: *sqlite.Database) !void {
    try database.executeScript(
        \\CREATE TABLE IF NOT EXISTS model_downloads (
        \\  id TEXT PRIMARY KEY,
        \\  data TEXT NOT NULL,
        \\  created_at TEXT DEFAULT CURRENT_TIMESTAMP,
        \\  updated_at TEXT DEFAULT CURRENT_TIMESTAMP
        \\);
    );
}

pub fn rehydrate(allocator: std.mem.Allocator, database: *sqlite.Database) !void {
    var statement = try database.prepare("SELECT id, data FROM model_downloads");
    defer statement.deinit();
    var updates: std.ArrayList(Update) = .empty;
    defer {
        for (updates.items) |update| {
            allocator.free(update.id);
            allocator.free(update.data);
        }
        updates.deinit(allocator);
    }
    while (try statement.step() == .row) {
        const row_id = statement.columnText(0) orelse continue;
        const data = statement.columnText(1) orelse continue;
        if (data.len > max_record_bytes) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch continue;
        defer parsed.deinit();
        if (!validDownload(parsed.value)) continue;
        const status = parsed.value.object.get("status").?.string;
        if (!std.mem.eql(u8, status, "queued") and !std.mem.eql(u8, status, "downloading")) continue;
        try parsed.value.object.put(parsed.arena.allocator(), "status", .{ .string = "paused" });
        try parsed.value.object.put(parsed.arena.allocator(), "error", .{ .string = "Restart required" });
        const normalized = try stringify(allocator, parsed.value);
        errdefer allocator.free(normalized);
        try updates.append(allocator, .{ .id = try allocator.dupe(u8, row_id), .data = normalized });
    }
    statement.deinit();
    for (updates.items) |update| try save(database, update.id, update.data);
}

pub fn listPayload(allocator: std.mem.Allocator, database: *sqlite.Database) ![]u8 {
    var statement = try database.prepare("SELECT data FROM model_downloads ORDER BY updated_at DESC");
    defer statement.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"downloads\":[");
    var wrote = false;
    while (try statement.step() == .row) {
        const data = statement.columnText(0) orelse continue;
        const normalized = try normalizedData(allocator, data) orelse continue;
        defer allocator.free(normalized);
        if (wrote) try output.writer.writeByte(',');
        try output.writer.writeAll(normalized);
        wrote = true;
    }
    try output.writer.writeAll("]}");
    return output.toOwnedSlice();
}

pub fn getPayload(allocator: std.mem.Allocator, database: *sqlite.Database, id: []const u8) !?[]u8 {
    var statement = try database.prepare("SELECT data FROM model_downloads WHERE id = ?");
    defer statement.deinit();
    try statement.bindText(1, id);
    if (try statement.step() != .row) return null;
    const data = statement.columnText(0) orelse return null;
    return try normalizedData(allocator, data);
}

pub fn save(database: *sqlite.Database, id: []const u8, data: []const u8) !void {
    var statement = try database.prepare(
        \\INSERT INTO model_downloads (id, data, updated_at) VALUES (?, ?, CURRENT_TIMESTAMP)
        \\ON CONFLICT(id) DO UPDATE SET data = excluded.data, updated_at = CURRENT_TIMESTAMP
    );
    defer statement.deinit();
    try statement.bindText(1, id);
    try statement.bindText(2, data);
    if (try statement.step() != .done) return error.DatabaseUnexpectedRow;
}

pub fn normalizedData(allocator: std.mem.Allocator, data: []const u8) !?[]u8 {
    if (data.len > max_record_bytes) return null;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return null;
    defer parsed.deinit();
    if (!validDownload(parsed.value)) return null;
    try normalizeTotal(&parsed.value, parsed.arena.allocator());
    return try stringify(allocator, parsed.value);
}

pub fn validDownload(value: std.json.Value) bool {
    if (value != .object) return false;
    const object = value.object;
    if (!requiredString(object, "id") or !requiredString(object, "model_id")) return false;
    if (!nullableString(object.get("revision"))) return false;
    const status = object.get("status") orelse return false;
    if (status != .string or !downloadStatus(status.string)) return false;
    if (!requiredString(object, "created_at") or !requiredString(object, "updated_at")) return false;
    if (!requiredString(object, "target_dir")) return false;
    if (!nullableNumber(object.get("total_bytes")) or !requiredNumber(object, "downloaded_bytes")) return false;
    const files = object.get("files") orelse return false;
    if (files != .array or files.array.items.len > max_files) return false;
    for (files.array.items) |file| if (!validFile(file)) return false;
    if (!nullableString(object.get("error"))) return false;
    if (object.get("source")) |source| if (!nullableString(source)) return false;
    if (object.get("completed_at")) |completed| if (!nullableString(completed)) return false;
    if (object.get("speed_bytes_per_second")) |speed| if (!nullableNumber(speed)) return false;
    return true;
}

fn validFile(value: std.json.Value) bool {
    if (value != .object) return false;
    const object = value.object;
    if (!requiredString(object, "path")) return false;
    if (!nullableNumber(object.get("size_bytes")) or !requiredNumber(object, "downloaded_bytes")) return false;
    const status = object.get("status") orelse return false;
    return status == .string and fileStatus(status.string);
}

fn normalizeTotal(value: *std.json.Value, allocator: std.mem.Allocator) !void {
    const object = &value.object;
    const files = object.get("files").?.array.items;
    var complete = files.len > 0;
    var total: f64 = 0;
    for (files) |file| {
        const size = file.object.get("size_bytes") orelse unreachable;
        if (size == .null) {
            complete = false;
            break;
        }
        total += number(size) orelse unreachable;
        if (!std.math.isFinite(total)) {
            complete = false;
            break;
        }
    }
    if (complete) {
        try object.put(allocator, "total_bytes", numberValue(total));
        return;
    }
    const downloaded = number(object.get("downloaded_bytes").?) orelse unreachable;
    const stored = object.get("total_bytes").?;
    if (stored == .null or (number(stored) orelse -1) < downloaded) try object.put(allocator, "total_bytes", .null);
}

fn numberValue(value: f64) std.json.Value {
    if (value >= @as(f64, @floatFromInt(std.math.minInt(i64))) and value <= @as(f64, @floatFromInt(std.math.maxInt(i64)))) {
        const integer: i64 = @intFromFloat(value);
        if (@as(f64, @floatFromInt(integer)) == value) return .{ .integer = integer };
    }
    return .{ .float = value };
}

fn requiredString(object: std.json.ObjectMap, name: []const u8) bool {
    const value = object.get(name) orelse return false;
    return value == .string;
}

fn nullableString(value: ?std.json.Value) bool {
    const present = value orelse return false;
    return present == .null or present == .string;
}

fn requiredNumber(object: std.json.ObjectMap, name: []const u8) bool {
    return if (object.get(name)) |value| number(value) != null else false;
}

fn nullableNumber(value: ?std.json.Value) bool {
    const present = value orelse return false;
    return present == .null or number(present) != null;
}

fn number(value: std.json.Value) ?f64 {
    const result: f64 = switch (value) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        .number_string => |text| std.fmt.parseFloat(f64, text) catch return null,
        else => return null,
    };
    return if (std.math.isFinite(result)) result else null;
}

fn downloadStatus(value: []const u8) bool {
    return std.mem.eql(u8, value, "queued") or std.mem.eql(u8, value, "downloading") or std.mem.eql(u8, value, "paused") or std.mem.eql(u8, value, "completed") or std.mem.eql(u8, value, "failed") or std.mem.eql(u8, value, "canceled");
}

fn fileStatus(value: []const u8) bool {
    return std.mem.eql(u8, value, "pending") or std.mem.eql(u8, value, "downloading") or std.mem.eql(u8, value, "completed") or std.mem.eql(u8, value, "error");
}

fn stringify(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try std.json.Stringify.value(value, .{}, &output.writer);
    return output.toOwnedSlice();
}

const Update = struct {
    id: []u8,
    data: []u8,
};
