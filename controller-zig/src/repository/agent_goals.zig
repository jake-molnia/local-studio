const std = @import("std");
const sqlite = @import("sqlite.zig");

pub fn initialize(database: *sqlite.Database) !void {
    try database.executeScript(
        \\CREATE TABLE IF NOT EXISTS agent_goals (
        \\  session_id TEXT PRIMARY KEY,
        \\  data TEXT NOT NULL,
        \\  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        \\);
    );
}

pub fn get(allocator: std.mem.Allocator, database: *sqlite.Database, session_id: []const u8) !?[]u8 {
    var statement = try database.prepare("SELECT data FROM agent_goals WHERE session_id = ?");
    defer statement.deinit();
    try statement.bindText(1, session_id);
    if (try statement.step() != .row) return null;
    const document = statement.columnText(0) orelse return null;
    if (!try std.json.validate(allocator, document)) return error.InvalidGoalRecord;
    return @as(?[]u8, try allocator.dupe(u8, document));
}

pub fn save(database: *sqlite.Database, session_id: []const u8, document: []const u8) !void {
    var statement = try database.prepare(
        \\INSERT INTO agent_goals (session_id, data, updated_at)
        \\VALUES (?, ?, CURRENT_TIMESTAMP)
        \\ON CONFLICT(session_id) DO UPDATE SET
        \\  data = excluded.data,
        \\  updated_at = CURRENT_TIMESTAMP
    );
    defer statement.deinit();
    try statement.bindText(1, session_id);
    try statement.bindText(2, document);
    if (try statement.step() != .done) return error.DatabaseUnexpectedRow;
}

pub fn delete(database: *sqlite.Database, session_id: []const u8) !void {
    var statement = try database.prepare("DELETE FROM agent_goals WHERE session_id = ?");
    defer statement.deinit();
    try statement.bindText(1, session_id);
    if (try statement.step() != .done) return error.DatabaseUnexpectedRow;
}
