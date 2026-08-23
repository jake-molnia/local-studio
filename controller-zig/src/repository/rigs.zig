const std = @import("std");
const sqlite = @import("sqlite.zig");

pub const List = struct {
    allocator: std.mem.Allocator,
    storage: [][]u8,
    len: usize,

    pub fn items(rigs: *const List) []const []const u8 {
        return rigs.storage[0..rigs.len];
    }

    pub fn deinit(rigs: *List) void {
        for (rigs.storage[0..rigs.len]) |item| rigs.allocator.free(item);
        rigs.allocator.free(rigs.storage);
        rigs.* = undefined;
    }
};

pub fn initialize(database: *sqlite.Database) !void {
    try database.executeScript(
        \\CREATE TABLE IF NOT EXISTS rigs (
        \\  id TEXT PRIMARY KEY,
        \\  data TEXT NOT NULL,
        \\  created_at TEXT DEFAULT CURRENT_TIMESTAMP,
        \\  updated_at TEXT DEFAULT CURRENT_TIMESTAMP
        \\);
    );
}

pub fn list(allocator: std.mem.Allocator, database: *sqlite.Database) !List {
    var count_statement = try database.prepare("SELECT COUNT(*) FROM rigs");
    defer count_statement.deinit();
    if (try count_statement.step() != .row) return error.DatabaseQueryFailed;
    const row_count = count_statement.columnInt(0);
    if (row_count < 0) return error.DatabaseInvalidRowCount;
    const capacity = std.math.cast(usize, row_count) orelse return error.DatabaseInvalidRowCount;
    const storage = try allocator.alloc([]u8, capacity);
    errdefer allocator.free(storage);

    var result: List = .{ .allocator = allocator, .storage = storage, .len = 0 };
    errdefer result.deinit();
    var statement = try database.prepare("SELECT data FROM rigs ORDER BY created_at");
    defer statement.deinit();
    while (try statement.step() == .row) {
        const data = statement.columnText(0) orelse continue;
        if (!try std.json.validate(allocator, data)) continue;
        result.storage[result.len] = try allocator.dupe(u8, data);
        result.len += 1;
    }
    return result;
}
