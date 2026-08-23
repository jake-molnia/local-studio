const std = @import("std");
const sqlite = @import("sqlite.zig");

pub const DocumentList = struct {
    allocator: std.mem.Allocator,
    documents: [][]u8,

    pub fn deinit(document_list: *DocumentList) void {
        for (document_list.documents) |document| document_list.allocator.free(document);
        document_list.allocator.free(document_list.documents);
        document_list.* = undefined;
    }
};

pub fn initialize(database: *sqlite.Database) !void {
    try database.executeScript(
        \\CREATE TABLE IF NOT EXISTS agent_connectors (
        \\  connector_id TEXT PRIMARY KEY,
        \\  enabled INTEGER NOT NULL,
        \\  data TEXT NOT NULL,
        \\  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
        \\  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        \\);
        \\CREATE TABLE IF NOT EXISTS agent_connector_grants (
        \\  model_id TEXT NOT NULL,
        \\  connector_id TEXT NOT NULL,
        \\  tools_json TEXT NOT NULL,
        \\  created_at TEXT NOT NULL,
        \\  PRIMARY KEY (model_id, connector_id)
        \\);
        \\CREATE TABLE IF NOT EXISTS agent_connector_grant_seeds (
        \\  connector_id TEXT PRIMARY KEY
        \\);
    );
}

pub fn list(allocator: std.mem.Allocator, database: *sqlite.Database) !DocumentList {
    return queryDocuments(allocator, database, "SELECT data FROM agent_connectors ORDER BY connector_id LIMIT 10000");
}

pub fn listEnabled(allocator: std.mem.Allocator, database: *sqlite.Database) !DocumentList {
    return queryDocuments(allocator, database, "SELECT data FROM agent_connectors WHERE enabled = 1 ORDER BY connector_id LIMIT 10000");
}

pub fn get(allocator: std.mem.Allocator, database: *sqlite.Database, id: []const u8) !?[]u8 {
    var statement = try database.prepare("SELECT data FROM agent_connectors WHERE connector_id = ?");
    defer statement.deinit();
    try statement.bindText(1, id);
    if (try statement.step() != .row) return null;
    return @as(?[]u8, try allocator.dupe(u8, statement.columnText(0) orelse return error.InvalidConnectorRecord));
}

pub fn save(database: *sqlite.Database, id: []const u8, enabled: bool, document: []const u8) !void {
    var statement = try database.prepare(
        \\INSERT INTO agent_connectors (connector_id, enabled, data, updated_at) VALUES (?, ?, ?, CURRENT_TIMESTAMP)
        \\ON CONFLICT(connector_id) DO UPDATE SET enabled = excluded.enabled, data = excluded.data, updated_at = CURRENT_TIMESTAMP
    );
    defer statement.deinit();
    try statement.bindText(1, id);
    try statement.bindInt(2, if (enabled) 1 else 0);
    try statement.bindText(3, document);
    if (try statement.step() != .done) return error.DatabaseUnexpectedRow;
}

pub fn delete(database: *sqlite.Database, id: []const u8) !void {
    var statement = try database.prepare("DELETE FROM agent_connectors WHERE connector_id = ?");
    defer statement.deinit();
    try statement.bindText(1, id);
    if (try statement.step() != .done) return error.DatabaseUnexpectedRow;
}

fn queryDocuments(allocator: std.mem.Allocator, database: *sqlite.Database, sql: []const u8) !DocumentList {
    var documents: std.ArrayList([]u8) = .empty;
    errdefer {
        for (documents.items) |document| allocator.free(document);
        documents.deinit(allocator);
    }
    var statement = try database.prepare(sql);
    defer statement.deinit();
    while (try statement.step() == .row) {
        const document = statement.columnText(0) orelse return error.InvalidConnectorRecord;
        try documents.append(allocator, try allocator.dupe(u8, document));
    }
    return .{ .allocator = allocator, .documents = try documents.toOwnedSlice(allocator) };
}
