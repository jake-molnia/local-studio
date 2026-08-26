const std = @import("std");
const sqlite = @import("../../storage/sqlite.zig");

const Io = std.Io;

pub const Message = struct {
    allocator: std.mem.Allocator,
    id: []u8,
    provider: []u8,
    account_id: []u8,
    external_user_id: []u8,
    conversation_id: []u8,
    prompt: []u8,

    pub fn deinit(message: *Message) void {
        message.allocator.free(message.id);
        message.allocator.free(message.provider);
        message.allocator.free(message.account_id);
        message.allocator.free(message.external_user_id);
        message.allocator.free(message.conversation_id);
        message.allocator.free(message.prompt);
        message.* = undefined;
    }
};

pub const PairingResult = union(enum) {
    existing,
    limited,
    code: [8]u8,
};

pub fn initialize(database: *sqlite.Database) !void {
    try database.executeScript(
        \\CREATE TABLE IF NOT EXISTS agent_messaging_pairings (
        \\  pairing_id TEXT PRIMARY KEY,
        \\  provider TEXT NOT NULL CHECK(provider IN ('telegram', 'discord')),
        \\  account_id TEXT NOT NULL,
        \\  external_user_id TEXT NOT NULL,
        \\  external_label TEXT,
        \\  code_hash TEXT NOT NULL,
        \\  status TEXT NOT NULL CHECK(status IN ('pending', 'approved', 'expired', 'locked')),
        \\  failures INTEGER NOT NULL DEFAULT 0,
        \\  expires_at TEXT NOT NULL,
        \\  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
        \\  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        \\);
        \\CREATE INDEX IF NOT EXISTS idx_agent_messaging_pairings_pending ON agent_messaging_pairings(status, expires_at);
        \\CREATE TABLE IF NOT EXISTS agent_messaging_allowlist (
        \\  provider TEXT NOT NULL,
        \\  account_id TEXT NOT NULL,
        \\  external_user_id TEXT NOT NULL,
        \\  external_label TEXT,
        \\  approved_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
        \\  last_seen_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
        \\  PRIMARY KEY(provider, account_id, external_user_id)
        \\);
        \\CREATE TABLE IF NOT EXISTS agent_messaging_inbox (
        \\  message_id TEXT PRIMARY KEY,
        \\  provider TEXT NOT NULL CHECK(provider IN ('telegram', 'discord')),
        \\  account_id TEXT NOT NULL,
        \\  external_user_id TEXT NOT NULL,
        \\  conversation_id TEXT NOT NULL,
        \\  external_message_id TEXT NOT NULL,
        \\  prompt TEXT NOT NULL,
        \\  status TEXT NOT NULL CHECK(status IN ('queued', 'running', 'completed', 'failed')),
        \\  failure TEXT,
        \\  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
        \\  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
        \\  UNIQUE(provider, account_id, external_message_id)
        \\);
        \\CREATE INDEX IF NOT EXISTS idx_agent_messaging_inbox_queue ON agent_messaging_inbox(status, created_at);
        \\CREATE TABLE IF NOT EXISTS agent_messaging_cursors (
        \\  provider TEXT NOT NULL,
        \\  account_id TEXT NOT NULL,
        \\  cursor TEXT NOT NULL,
        \\  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
        \\  PRIMARY KEY(provider, account_id)
        \\);
    );
}

pub fn allowed(database: *sqlite.Database, provider: []const u8, account_id: []const u8, external_user_id: []const u8) !bool {
    var statement = try database.prepare("SELECT 1 FROM agent_messaging_allowlist WHERE provider = ? AND account_id = ? AND external_user_id = ?");
    defer statement.deinit();
    try statement.bindText(1, provider);
    try statement.bindText(2, account_id);
    try statement.bindText(3, external_user_id);
    const present = try statement.step() == .row;
    if (present) {
        var touch = try database.prepare("UPDATE agent_messaging_allowlist SET last_seen_at = CURRENT_TIMESTAMP WHERE provider = ? AND account_id = ? AND external_user_id = ?");
        defer touch.deinit();
        try touch.bindText(1, provider);
        try touch.bindText(2, account_id);
        try touch.bindText(3, external_user_id);
        if (try touch.step() != .done) return error.DatabaseUnexpectedRow;
    }
    return present;
}

pub fn requestPairing(database: *sqlite.Database, io: Io, provider: []const u8, account_id: []const u8, external_user_id: []const u8, external_label: ?[]const u8) !PairingResult {
    try expirePairings(database);
    var pending = try database.prepare("SELECT 1 FROM agent_messaging_pairings WHERE provider = ? AND account_id = ? AND external_user_id = ? AND status = 'pending' AND expires_at > CURRENT_TIMESTAMP LIMIT 1");
    defer pending.deinit();
    try pending.bindText(1, provider);
    try pending.bindText(2, account_id);
    try pending.bindText(3, external_user_id);
    if (try pending.step() == .row) return .existing;
    var recent = try database.prepare("SELECT COUNT(*) FROM agent_messaging_pairings WHERE provider = ? AND account_id = ? AND external_user_id = ? AND created_at > datetime('now', '-1 hour')");
    defer recent.deinit();
    try recent.bindText(1, provider);
    try recent.bindText(2, account_id);
    try recent.bindText(3, external_user_id);
    if (try recent.step() != .row) return error.DatabaseQueryFailed;
    if (recent.columnInt(0) >= 3) return .limited;
    const pairing_id = randomId(io);
    var code: [8]u8 = undefined;
    const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    var random: [8]u8 = undefined;
    io.random(&random);
    for (random, 0..) |byte, index| code[index] = alphabet[byte % alphabet.len];
    const code_hash = hashCode(code[0..]);
    var statement = try database.prepare("INSERT INTO agent_messaging_pairings (pairing_id, provider, account_id, external_user_id, external_label, code_hash, status, expires_at) VALUES (?, ?, ?, ?, ?, ?, 'pending', datetime('now', '+1 hour'))");
    defer statement.deinit();
    try statement.bindText(1, pairing_id[0..]);
    try statement.bindText(2, provider);
    try statement.bindText(3, account_id);
    try statement.bindText(4, external_user_id);
    if (external_label) |value| try statement.bindText(5, value) else try statement.bindNull(5);
    try statement.bindText(6, code_hash[0..]);
    if (try statement.step() != .done) return error.DatabaseUnexpectedRow;
    return .{ .code = code };
}

pub fn approve(database: *sqlite.Database, pairing_id: []const u8, code: []const u8) !void {
    try expirePairings(database);
    var statement = try database.prepare("SELECT provider, account_id, external_user_id, external_label, code_hash, failures FROM agent_messaging_pairings WHERE pairing_id = ? AND status = 'pending' AND expires_at > CURRENT_TIMESTAMP");
    defer statement.deinit();
    try statement.bindText(1, pairing_id);
    if (try statement.step() != .row) return error.PairingNotFound;
    const expected = statement.columnText(4) orelse return error.InvalidPairingRecord;
    const actual = hashCode(std.mem.trim(u8, code, " \t\r\n"));
    if (expected.len != 64 or !std.crypto.timing_safe.eql([64]u8, actual, expected[0..64].*)) {
        const failures = statement.columnInt(5) + 1;
        var fail = try database.prepare("UPDATE agent_messaging_pairings SET failures = ?, status = CASE WHEN ? >= 5 THEN 'locked' ELSE status END, updated_at = CURRENT_TIMESTAMP WHERE pairing_id = ?");
        defer fail.deinit();
        try fail.bindInt(1, failures);
        try fail.bindInt(2, failures);
        try fail.bindText(3, pairing_id);
        if (try fail.step() != .done) return error.DatabaseUnexpectedRow;
        return if (failures >= 5) error.PairingLocked else error.PairingCodeInvalid;
    }
    const provider = statement.columnText(0) orelse return error.InvalidPairingRecord;
    const account_id = statement.columnText(1) orelse return error.InvalidPairingRecord;
    const external_user_id = statement.columnText(2) orelse return error.InvalidPairingRecord;
    const external_label = statement.columnText(3);
    var transaction = try database.begin();
    defer transaction.deinit();
    var allow = try database.prepare("INSERT INTO agent_messaging_allowlist (provider, account_id, external_user_id, external_label) VALUES (?, ?, ?, ?) ON CONFLICT(provider, account_id, external_user_id) DO UPDATE SET external_label = excluded.external_label, approved_at = CURRENT_TIMESTAMP, last_seen_at = CURRENT_TIMESTAMP");
    defer allow.deinit();
    try allow.bindText(1, provider);
    try allow.bindText(2, account_id);
    try allow.bindText(3, external_user_id);
    if (external_label) |value| try allow.bindText(4, value) else try allow.bindNull(4);
    if (try allow.step() != .done) return error.DatabaseUnexpectedRow;
    var approve_statement = try database.prepare("UPDATE agent_messaging_pairings SET status = 'approved', updated_at = CURRENT_TIMESTAMP WHERE pairing_id = ?");
    defer approve_statement.deinit();
    try approve_statement.bindText(1, pairing_id);
    if (try approve_statement.step() != .done) return error.DatabaseUnexpectedRow;
    try transaction.commit();
}

pub fn revoke(database: *sqlite.Database, provider: []const u8, account_id: []const u8, external_user_id: []const u8) !void {
    var statement = try database.prepare("DELETE FROM agent_messaging_allowlist WHERE provider = ? AND account_id = ? AND external_user_id = ?");
    defer statement.deinit();
    try statement.bindText(1, provider);
    try statement.bindText(2, account_id);
    try statement.bindText(3, external_user_id);
    if (try statement.step() != .done) return error.DatabaseUnexpectedRow;
}

pub fn enqueue(database: *sqlite.Database, io: Io, provider: []const u8, account_id: []const u8, external_user_id: []const u8, conversation_id: []const u8, external_message_id: []const u8, prompt: []const u8) !void {
    const message_id = randomId(io);
    var statement = try database.prepare("INSERT OR IGNORE INTO agent_messaging_inbox (message_id, provider, account_id, external_user_id, conversation_id, external_message_id, prompt, status) VALUES (?, ?, ?, ?, ?, ?, ?, 'queued')");
    defer statement.deinit();
    try statement.bindText(1, message_id[0..]);
    try statement.bindText(2, provider);
    try statement.bindText(3, account_id);
    try statement.bindText(4, external_user_id);
    try statement.bindText(5, conversation_id);
    try statement.bindText(6, external_message_id);
    try statement.bindText(7, prompt);
    if (try statement.step() != .done) return error.DatabaseUnexpectedRow;
}

pub fn rateAllowed(database: *sqlite.Database, provider: []const u8, account_id: []const u8, external_user_id: []const u8) !bool {
    var statement = try database.prepare("SELECT COUNT(*) FROM agent_messaging_inbox WHERE provider = ? AND account_id = ? AND external_user_id = ? AND created_at > datetime('now', '-1 minute')");
    defer statement.deinit();
    try statement.bindText(1, provider);
    try statement.bindText(2, account_id);
    try statement.bindText(3, external_user_id);
    if (try statement.step() != .row) return error.DatabaseQueryFailed;
    return statement.columnInt(0) < 10;
}

pub fn takeNext(allocator: std.mem.Allocator, database: *sqlite.Database) !?Message {
    var transaction = try database.begin();
    defer transaction.deinit();
    var statement = try database.prepare("SELECT message_id, provider, account_id, external_user_id, conversation_id, prompt FROM agent_messaging_inbox WHERE status = 'queued' ORDER BY created_at LIMIT 1");
    defer statement.deinit();
    if (try statement.step() != .row) return null;
    var message = Message{
        .allocator = allocator,
        .id = try allocator.dupe(u8, statement.columnText(0) orelse return error.InvalidMessagingRecord),
        .provider = undefined,
        .account_id = undefined,
        .external_user_id = undefined,
        .conversation_id = undefined,
        .prompt = undefined,
    };
    errdefer allocator.free(message.id);
    message.provider = try allocator.dupe(u8, statement.columnText(1) orelse return error.InvalidMessagingRecord);
    errdefer allocator.free(message.provider);
    message.account_id = try allocator.dupe(u8, statement.columnText(2) orelse return error.InvalidMessagingRecord);
    errdefer allocator.free(message.account_id);
    message.external_user_id = try allocator.dupe(u8, statement.columnText(3) orelse return error.InvalidMessagingRecord);
    errdefer allocator.free(message.external_user_id);
    message.conversation_id = try allocator.dupe(u8, statement.columnText(4) orelse return error.InvalidMessagingRecord);
    errdefer allocator.free(message.conversation_id);
    message.prompt = try allocator.dupe(u8, statement.columnText(5) orelse return error.InvalidMessagingRecord);
    errdefer allocator.free(message.prompt);
    var claim = try database.prepare("UPDATE agent_messaging_inbox SET status = 'running', updated_at = CURRENT_TIMESTAMP WHERE message_id = ? AND status = 'queued'");
    defer claim.deinit();
    try claim.bindText(1, message.id);
    if (try claim.step() != .done or database.changes() != 1) return error.MessagingClaimFailed;
    try transaction.commit();
    return message;
}

pub fn finish(database: *sqlite.Database, message_id: []const u8, failure: ?[]const u8) !void {
    var statement = try database.prepare("UPDATE agent_messaging_inbox SET status = ?, failure = ?, updated_at = CURRENT_TIMESTAMP WHERE message_id = ?");
    defer statement.deinit();
    try statement.bindText(1, if (failure == null) "completed" else "failed");
    if (failure) |value| try statement.bindText(2, value) else try statement.bindNull(2);
    try statement.bindText(3, message_id);
    if (try statement.step() != .done) return error.DatabaseUnexpectedRow;
}

pub fn cursor(allocator: std.mem.Allocator, database: *sqlite.Database, provider: []const u8, account_id: []const u8) !?[]u8 {
    var statement = try database.prepare("SELECT cursor FROM agent_messaging_cursors WHERE provider = ? AND account_id = ?");
    defer statement.deinit();
    try statement.bindText(1, provider);
    try statement.bindText(2, account_id);
    if (try statement.step() != .row) return null;
    const value = statement.columnText(0) orelse return null;
    return try allocator.dupe(u8, value);
}

pub fn saveCursor(database: *sqlite.Database, provider: []const u8, account_id: []const u8, value: []const u8) !void {
    var statement = try database.prepare("INSERT INTO agent_messaging_cursors (provider, account_id, cursor) VALUES (?, ?, ?) ON CONFLICT(provider, account_id) DO UPDATE SET cursor = excluded.cursor, updated_at = CURRENT_TIMESTAMP");
    defer statement.deinit();
    try statement.bindText(1, provider);
    try statement.bindText(2, account_id);
    try statement.bindText(3, value);
    if (try statement.step() != .done) return error.DatabaseUnexpectedRow;
}

pub fn accessPayload(allocator: std.mem.Allocator, database: *sqlite.Database) ![]u8 {
    try expirePairings(database);
    var output: Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"pending\":[");
    var pending = try database.prepare("SELECT pairing_id, provider, account_id, external_user_id, external_label, expires_at, failures FROM agent_messaging_pairings WHERE status = 'pending' AND expires_at > CURRENT_TIMESTAMP ORDER BY created_at DESC");
    defer pending.deinit();
    var first = true;
    while (try pending.step() == .row) {
        if (!first) try output.writer.writeByte(',');
        first = false;
        try writeAccessRecord(&output.writer, &pending, true);
    }
    try output.writer.writeAll("],\"allowed\":[");
    var allowed_statement = try database.prepare("SELECT provider, account_id, external_user_id, external_label, approved_at, last_seen_at FROM agent_messaging_allowlist ORDER BY approved_at DESC");
    defer allowed_statement.deinit();
    first = true;
    while (try allowed_statement.step() == .row) {
        if (!first) try output.writer.writeByte(',');
        first = false;
        try output.writer.writeAll("{\"provider\":");
        try jsonColumn(&output.writer, &allowed_statement, 0);
        try output.writer.writeAll(",\"accountId\":");
        try jsonColumn(&output.writer, &allowed_statement, 1);
        try output.writer.writeAll(",\"externalUserId\":");
        try jsonColumn(&output.writer, &allowed_statement, 2);
        try output.writer.writeAll(",\"label\":");
        try nullableJsonColumn(&output.writer, &allowed_statement, 3);
        try output.writer.writeAll(",\"approvedAt\":");
        try jsonColumn(&output.writer, &allowed_statement, 4);
        try output.writer.writeAll(",\"lastSeenAt\":");
        try jsonColumn(&output.writer, &allowed_statement, 5);
        try output.writer.writeByte('}');
    }
    try output.writer.writeAll("]}");
    return output.toOwnedSlice();
}

fn writeAccessRecord(writer: *Io.Writer, statement: *sqlite.Statement, _: bool) !void {
    try writer.writeAll("{\"id\":");
    try jsonColumn(writer, statement, 0);
    try writer.writeAll(",\"provider\":");
    try jsonColumn(writer, statement, 1);
    try writer.writeAll(",\"accountId\":");
    try jsonColumn(writer, statement, 2);
    try writer.writeAll(",\"externalUserId\":");
    try jsonColumn(writer, statement, 3);
    try writer.writeAll(",\"label\":");
    try nullableJsonColumn(writer, statement, 4);
    try writer.writeAll(",\"expiresAt\":");
    try jsonColumn(writer, statement, 5);
    try writer.writeAll(",\"failures\":");
    try writer.print("{d}", .{statement.columnInt(6)});
    try writer.writeByte('}');
}

fn expirePairings(database: *sqlite.Database) !void {
    try database.execute("UPDATE agent_messaging_pairings SET status = 'expired', updated_at = CURRENT_TIMESTAMP WHERE status = 'pending' AND expires_at <= CURRENT_TIMESTAMP");
}

fn randomId(io: Io) [36]u8 {
    var bytes: [18]u8 = undefined;
    io.random(&bytes);
    return std.fmt.bytesToHex(bytes, .lower);
}

fn hashCode(code: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(code, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn jsonColumn(writer: *Io.Writer, statement: *sqlite.Statement, column: u31) !void {
    try std.json.Stringify.value(statement.columnText(column) orelse "", .{}, writer);
}

fn nullableJsonColumn(writer: *Io.Writer, statement: *sqlite.Statement, column: u31) !void {
    if (statement.columnText(column)) |value| try std.json.Stringify.value(value, .{}, writer) else try writer.writeAll("null");
}
