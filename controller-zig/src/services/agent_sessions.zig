const std = @import("std");
const records = @import("../repository/agent_control.zig");
const sqlite = @import("../repository/sqlite.zig");

const Io = std.Io;

pub fn payload(allocator: std.mem.Allocator, io: Io, database: *sqlite.Database) ![]u8 {
    try database.lock(io);
    defer database.unlock(io);
    var sessions = try records.list(allocator, database);
    defer sessions.deinit();
    var output: Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"sessions\":[");
    for (sessions.records, 0..) |session, index| {
        if (index > 0) try output.writer.writeByte(',');
        try writeMetadata(&output.writer, &session);
    }
    try output.writer.writeAll("]}");
    return output.toOwnedSlice();
}

pub fn upsert(allocator: std.mem.Allocator, io: Io, database: *sqlite.Database, session_id: []const u8, document: []const u8) ![]u8 {
    if (!validSessionId(session_id)) return error.InvalidSessionId;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, document, .{}) catch return error.InvalidSessionMetadata;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidSessionMetadata;
    try database.lock(io);
    defer database.unlock(io);
    var existing = try records.get(allocator, database, session_id);
    defer if (existing) |*session| session.deinit();
    const object = parsed.value.object;
    const node_id = optionalString(object, "desktop_id") orelse optionalString(object, "node_id") orelse if (existing) |session| session.node_id else return error.SessionNodeRequired;
    const harness = optionalString(object, "harness") orelse if (existing) |session| session.harness else "pi";
    const status = optionalString(object, "status") orelse if (existing) |session| session.status else "idle";
    const sharing = optionalString(object, "sharing_policy") orelse if (existing) |session| session.sharing_policy else "private";
    try records.save(database, .{
        .id = session_id,
        .harness = harness,
        .harness_version = optionalString(object, "harness_version") orelse if (existing) |session| session.harness_version else null,
        .capabilities_json = if (existing) |session| session.capabilities_json else "[]",
        .node_id = node_id,
        .native_session_id = optionalString(object, "native_session_id") orelse optionalString(object, "pi_session_id"),
        .project_id = optionalString(object, "project_id"),
        .project_path = optionalString(object, "project_path"),
        .model_id = optionalString(object, "model_id"),
        .status = status,
        .event_cursor = unsignedField(object, "event_cursor") orelse if (existing) |session| session.event_cursor else 0,
        .sharing_policy = sharing,
        .automation_id = optionalString(object, "automation_id"),
    });
    var saved = (try records.get(allocator, database, session_id)) orelse return error.SessionNotFound;
    defer saved.deinit();
    var output: Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"success\":true,\"session\":");
    try writeMetadata(&output.writer, &saved);
    try output.writer.writeByte('}');
    return output.toOwnedSlice();
}

fn writeMetadata(writer: *Io.Writer, session: *const records.Session) !void {
    try writer.writeAll("{\"session_id\":");
    try std.json.Stringify.value(session.id, .{}, writer);
    try writer.writeAll(",\"pi_session_id\":");
    if (session.native_session_id) |value| try std.json.Stringify.value(value, .{}, writer) else try writer.writeAll("null");
    try writer.writeAll(",\"native_session_id\":");
    if (session.native_session_id) |value| try std.json.Stringify.value(value, .{}, writer) else try writer.writeAll("null");
    try writer.writeAll(",\"desktop_id\":");
    try std.json.Stringify.value(session.node_id, .{}, writer);
    try writer.writeAll(",\"desktop_name\":");
    try std.json.Stringify.value(session.node_id, .{}, writer);
    try writer.writeAll(",\"project_id\":");
    if (session.project_id) |value| try std.json.Stringify.value(value, .{}, writer) else try writer.writeAll("null");
    try writer.writeAll(",\"project_name\":null,\"project_path\":");
    if (session.project_path) |value| try std.json.Stringify.value(value, .{}, writer) else try writer.writeAll("null");
    try writer.writeAll(",\"title\":");
    try std.json.Stringify.value(session.id, .{}, writer);
    try writer.writeAll(",\"last_message_preview\":null,\"status\":");
    try std.json.Stringify.value(session.status, .{}, writer);
    try writer.writeAll(",\"model_id\":");
    if (session.model_id) |value| try std.json.Stringify.value(value, .{}, writer) else try writer.writeAll("null");
    try writer.writeAll(",\"started_at\":");
    try std.json.Stringify.value(session.created_at, .{}, writer);
    try writer.writeAll(",\"updated_at\":");
    try std.json.Stringify.value(session.updated_at, .{}, writer);
    try writer.writeAll(",\"attachment_count\":0,\"attachments\":[],\"usage\":null,\"harness\":");
    try std.json.Stringify.value(session.harness, .{}, writer);
    try writer.writeAll(",\"harness_version\":");
    if (session.harness_version) |value| try std.json.Stringify.value(value, .{}, writer) else try writer.writeAll("null");
    try writer.writeAll(",\"capabilities\":");
    try writer.writeAll(session.capabilities_json);
    try writer.writeAll(",\"sharing_policy\":");
    try std.json.Stringify.value(session.sharing_policy, .{}, writer);
    try writer.print(",\"event_cursor\":{d},\"automation_id\":", .{session.event_cursor});
    if (session.automation_id) |value| try std.json.Stringify.value(value, .{}, writer) else try writer.writeAll("null");
    try writer.writeByte('}');
}

fn optionalString(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    if (value != .string) return null;
    const trimmed = std.mem.trim(u8, value.string, " \t\r\n");
    return if (trimmed.len > 0) trimmed else null;
}

fn unsignedField(object: std.json.ObjectMap, name: []const u8) ?u64 {
    const value = object.get(name) orelse return null;
    if (value != .integer or value.integer < 0) return null;
    return @intCast(value.integer);
}

fn validSessionId(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    for (value) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-' and byte != '.' and byte != ':') return false;
    return true;
}
