const std = @import("std");
const config = @import("../config.zig");
const records = @import("../repository/agent_control.zig");
const sqlite = @import("../repository/sqlite.zig");
const harness_nodes = @import("harness_nodes.zig");
const harness_runtime = @import("harness_runtime.zig");
const reverse_proxy = @import("../reverse_proxy.zig");

const Io = std.Io;
const http = std.http;
const max_response_bytes = 16 * 1024 * 1024;

const Response = struct {
    allocator: std.mem.Allocator,
    status: http.Status,
    storage: []u8,
    body: []const u8,

    fn deinit(response: *Response) void {
        response.allocator.free(response.storage);
        response.* = undefined;
    }
};

pub fn setupPayload(allocator: std.mem.Allocator, io: Io, mode: config.Mode, database: *sqlite.Database, harness: *harness_runtime.Manager) ![]u8 {
    if (mode == .standalone) return harness.setupPayload();
    const node_count = try harness_nodes.count(allocator, io, database, "pi");
    var output: Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.print("{{\"checks\":[{{\"id\":\"pi-rpc-node\",\"label\":\"Enrolled Pi harness node\",\"ok\":{},\"value\":\"{d}\",\"guidance\":\"Enroll a node that advertises the Pi harness capability.\"}}],\"diagnostics\":[]}}", .{ node_count > 0, node_count });
    return output.toOwnedSlice();
}

pub fn sessionsPayload(allocator: std.mem.Allocator, io: Io, database: *sqlite.Database) ![]u8 {
    try database.lock(io);
    defer database.unlock(io);
    var sessions = try records.list(allocator, database);
    defer sessions.deinit();
    var output: Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"sessions\":[");
    for (sessions.records, 0..) |session, index| {
        if (index > 0) try output.writer.writeByte(',');
        try output.writer.writeAll("{\"sessionId\":");
        try std.json.Stringify.value(session.id, .{}, &output.writer);
        try output.writer.writeAll(",\"harness\":");
        try std.json.Stringify.value(session.harness, .{}, &output.writer);
        try output.writer.writeAll(",\"nodeId\":");
        try std.json.Stringify.value(session.node_id, .{}, &output.writer);
        try output.writer.writeAll(",\"nativeSessionId\":");
        if (session.native_session_id) |value| try std.json.Stringify.value(value, .{}, &output.writer) else try output.writer.writeAll("null");
        try output.writer.writeAll(",\"projectId\":");
        if (session.project_id) |value| try std.json.Stringify.value(value, .{}, &output.writer) else try output.writer.writeAll("null");
        try output.writer.writeAll(",\"projectPath\":");
        if (session.project_path) |value| try std.json.Stringify.value(value, .{}, &output.writer) else try output.writer.writeAll("null");
        try output.writer.writeAll(",\"modelId\":");
        if (session.model_id) |value| try std.json.Stringify.value(value, .{}, &output.writer) else try output.writer.writeAll("null");
        try output.writer.writeAll(",\"status\":{\"phase\":");
        try std.json.Stringify.value(session.status, .{}, &output.writer);
        try output.writer.print(",\"eventSeq\":{d}}},\"sharingPolicy\":", .{session.event_cursor});
        try std.json.Stringify.value(session.sharing_policy, .{}, &output.writer);
        try output.writer.writeAll(",\"updatedAt\":");
        try std.json.Stringify.value(session.updated_at, .{}, &output.writer);
        try output.writer.writeByte('}');
    }
    try output.writer.writeAll("]}");
    return output.toOwnedSlice();
}

pub fn turnPayload(allocator: std.mem.Allocator, io: Io, mode: config.Mode, client: *http.Client, database: *sqlite.Database, harness: *harness_runtime.Manager, document: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, document, .{}) catch return error.InvalidTurnPayload;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidTurnPayload;
    const object = parsed.value.object;
    const session_id = optionalString(object, "sessionId") orelse "default";
    const model_id = optionalString(object, "modelId") orelse return error.ModelIdRequired;
    const message = optionalString(object, "message") orelse return error.MessageRequired;
    _ = message;
    const project_id = optionalString(object, "projectId");
    const project_path = optionalString(object, "cwd");
    const native_session_id = optionalString(object, "piSessionId");
    const requested_node = optionalString(object, "nodeId");
    const command_kind = optionalString(object, "mode") orelse "prompt";
    if (!validSessionId(session_id)) return error.InvalidSessionId;

    var existing = try lockedGet(allocator, io, database, session_id);
    defer if (existing) |*session| session.deinit();
    const preferred_node = if (existing) |session| session.node_id else requested_node;
    var target = if (mode == .head) try harness_nodes.select(allocator, io, database, "pi", preferred_node) else null;
    defer if (target) |*node| node.deinit();
    if (mode == .head and target == null) return if (preferred_node != null) error.AssignedHarnessUnavailable else error.HarnessNodeRequired;
    const node_id = if (mode == .standalone) "local" else target.?.id;
    if (existing) |session| if (!std.mem.eql(u8, session.node_id, node_id)) return error.SessionNodeMismatch;

    try lockedSave(allocator, io, database, .{
        .id = session_id,
        .harness = "pi",
        .node_id = node_id,
        .native_session_id = native_session_id,
        .project_id = project_id,
        .project_path = project_path,
        .model_id = model_id,
        .status = "queued",
        .event_cursor = if (existing) |session| session.event_cursor else 0,
        .sharing_policy = if (existing) |session| session.sharing_policy else "private",
    });
    const command_id = commandId(io);
    try lockedEnqueue(io, database, command_id[0..], session_id, command_kind, document);

    const payload = if (mode == .standalone)
        harness.turnPayload(document)
    else
        remotePost(allocator, client, &target.?, "/internal/harness/v1/turn", document);
    const response = payload catch |failure| {
        try lockedFinish(io, database, command_id[0..], "rejected", @errorName(failure));
        try lockedRuntime(io, database, session_id, "unavailable", null, null);
        return failure;
    };
    errdefer allocator.free(response);
    try lockedFinish(io, database, command_id[0..], "accepted", null);
    try ingestRuntimeDocument(allocator, io, database, session_id, response);
    return response;
}

pub fn statusPayload(allocator: std.mem.Allocator, io: Io, mode: config.Mode, client: *http.Client, database: *sqlite.Database, harness: *harness_runtime.Manager, session_id: []const u8, after: u64) ![]u8 {
    var session = (try lockedGet(allocator, io, database, session_id)) orelse return emptyStatus(allocator, session_id);
    defer session.deinit();
    const payload = if (mode == .standalone)
        try harness.statusPayload(session_id, after)
    else remote: {
        var target = (try harness_nodes.select(allocator, io, database, session.harness, session.node_id)) orelse {
            try lockedRuntime(io, database, session_id, "unavailable", null, null);
            try replaceSessionStatus(&session, "unavailable");
            return storedStatus(allocator, io, database, &session, after);
        };
        defer target.deinit();
        const path = try std.fmt.allocPrint(allocator, "/internal/harness/v1/status?sessionId={s}&after={d}", .{ session_id, after });
        defer allocator.free(path);
        break :remote remoteGet(allocator, client, &target, path) catch {
            try lockedRuntime(io, database, session_id, "unavailable", null, null);
            try replaceSessionStatus(&session, "unavailable");
            return storedStatus(allocator, io, database, &session, after);
        };
    };
    errdefer allocator.free(payload);
    try ingestRuntimeDocument(allocator, io, database, session_id, payload);
    return payload;
}

pub fn controlPayload(allocator: std.mem.Allocator, io: Io, mode: config.Mode, client: *http.Client, database: *sqlite.Database, harness: *harness_runtime.Manager, operation: []const u8, document: []const u8) ![]u8 {
    const session_id = try sessionIdFromDocument(allocator, document);
    defer allocator.free(session_id);
    var session = (try lockedGet(allocator, io, database, session_id)) orelse return error.SessionNotFound;
    defer session.deinit();
    if (mode == .standalone) {
        if (std.mem.eql(u8, operation, "abort")) return harness.abortPayload(document);
        if (std.mem.eql(u8, operation, "compact")) return harness.compactPayload(document);
        if (std.mem.eql(u8, operation, "extension-ui")) return harness.extensionUiPayload(document);
        return error.InvalidHarnessOperation;
    }
    var target = (try harness_nodes.select(allocator, io, database, session.harness, session.node_id)) orelse return error.AssignedHarnessUnavailable;
    defer target.deinit();
    const path = try std.fmt.allocPrint(allocator, "/internal/harness/v1/{s}", .{operation});
    defer allocator.free(path);
    return remotePost(allocator, client, &target, path, document);
}

pub fn serveEvents(allocator: std.mem.Allocator, io: Io, mode: config.Mode, client: *http.Client, database: *sqlite.Database, harness: *harness_runtime.Manager, session_id: []const u8, after: u64, request: *http.Server.Request) !void {
    if (mode == .standalone) return harness.serveEvents(session_id, after, request);
    var session = (try lockedGet(allocator, io, database, session_id)) orelse return error.SessionNotFound;
    defer session.deinit();
    var target = (try harness_nodes.select(allocator, io, database, session.harness, session.node_id)) orelse return error.AssignedHarnessUnavailable;
    defer target.deinit();
    var captured = try reverse_proxy.captureRequest(allocator, request);
    defer captured.deinit();
    allocator.free(captured.target);
    captured.target = try std.fmt.allocPrint(allocator, "/internal/harness/v1/events?sessionId={s}&after={d}", .{ session_id, after });
    try reverse_proxy.serveWorkerBuffered(allocator, client, target.address, target.api_key, target.id, "", &captured, request);
}

fn remotePost(allocator: std.mem.Allocator, client: *http.Client, target: *const harness_nodes.Target, path: []const u8, payload: []const u8) ![]u8 {
    var response = try fetch(allocator, client, target, path, .POST, payload);
    defer response.deinit();
    if (!success(response.status)) return error.HarnessCommandRejected;
    return allocator.dupe(u8, response.body);
}

fn remoteGet(allocator: std.mem.Allocator, client: *http.Client, target: *const harness_nodes.Target, path: []const u8) ![]u8 {
    var response = try fetch(allocator, client, target, path, .GET, null);
    defer response.deinit();
    if (!success(response.status)) return error.HarnessNodeUnavailable;
    return allocator.dupe(u8, response.body);
}

fn fetch(allocator: std.mem.Allocator, client: *http.Client, target: *const harness_nodes.Target, path: []const u8, method: http.Method, payload: ?[]const u8) !Response {
    const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ target.address, path });
    defer allocator.free(url);
    const authorization = if (target.api_key.len > 0) try std.fmt.allocPrint(allocator, "Bearer {s}", .{target.api_key}) else null;
    defer if (authorization) |value| allocator.free(value);
    var headers: [3]http.Header = undefined;
    headers[0] = .{ .name = "X-Local-Studio-Federation-Hop", .value = "head" };
    headers[1] = .{ .name = "Content-Type", .value = "application/json" };
    var count: usize = 2;
    if (authorization) |value| {
        headers[count] = .{ .name = "Authorization", .value = value };
        count += 1;
    }
    const storage = try allocator.alloc(u8, max_response_bytes);
    errdefer allocator.free(storage);
    var output: Io.Writer = .fixed(storage);
    const response = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = payload,
        .redirect_behavior = .unhandled,
        .keep_alive = false,
        .headers = .{ .accept_encoding = .omit },
        .extra_headers = headers[0..count],
        .response_writer = &output,
    });
    return .{ .allocator = allocator, .status = response.status, .storage = storage, .body = output.buffered() };
}

fn ingestRuntimeDocument(allocator: std.mem.Allocator, io: Io, database: *sqlite.Database, session_id: []const u8, document: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, document, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const status = parsed.value.object.get("status") orelse return;
    if (status != .object) return;
    const active = booleanField(status.object, "active") orelse false;
    const running = booleanField(status.object, "running") orelse active;
    const phase = if (active) "running" else if (running) "idle" else "stopped";
    const native_session_id = optionalString(status.object, "piSessionId");
    const cursor = unsignedField(status.object, "eventSeq");
    try lockedRuntime(io, database, session_id, phase, native_session_id, cursor);
    const events = parsed.value.object.get("events") orelse return;
    if (events != .array) return;
    try database.lock(io);
    defer database.unlock(io);
    for (events.array.items) |event| {
        if (event != .object) continue;
        const sequence = unsignedField(event.object, "seq") orelse continue;
        const serialized = try serialize(allocator, event);
        defer allocator.free(serialized);
        try records.appendEvent(database, session_id, sequence, "pi", serialized);
    }
}

fn storedStatus(allocator: std.mem.Allocator, io: Io, database: *sqlite.Database, session: *const records.Session, after: u64) ![]u8 {
    try database.lock(io);
    defer database.unlock(io);
    var events = try records.eventsAfter(allocator, database, session.id, after);
    defer events.deinit();
    var output: Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"sessionId\":");
    try std.json.Stringify.value(session.id, .{}, &output.writer);
    try output.writer.writeAll(",\"status\":{\"running\":false,\"active\":false,\"piSessionId\":");
    if (session.native_session_id) |value| try std.json.Stringify.value(value, .{}, &output.writer) else try output.writer.writeAll("null");
    try output.writer.print(",\"modelId\":", .{});
    if (session.model_id) |value| try std.json.Stringify.value(value, .{}, &output.writer) else try output.writer.writeAll("null");
    try output.writer.print(",\"eventSeq\":{d},\"phase\":", .{session.event_cursor});
    try std.json.Stringify.value(session.status, .{}, &output.writer);
    try output.writer.writeAll("},\"events\":[");
    for (events.records, 0..) |event, index| {
        if (index > 0) try output.writer.writeByte(',');
        try output.writer.writeAll(event.document);
    }
    try output.writer.writeAll("]}");
    return output.toOwnedSlice();
}

fn emptyStatus(allocator: std.mem.Allocator, session_id: []const u8) ![]u8 {
    var output: Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"sessionId\":");
    try std.json.Stringify.value(session_id, .{}, &output.writer);
    try output.writer.writeAll(",\"status\":null,\"events\":[]}");
    return output.toOwnedSlice();
}

fn lockedGet(allocator: std.mem.Allocator, io: Io, database: *sqlite.Database, session_id: []const u8) !?records.Session {
    try database.lock(io);
    defer database.unlock(io);
    return records.get(allocator, database, session_id);
}

fn lockedSave(_: std.mem.Allocator, io: Io, database: *sqlite.Database, input: records.SessionInput) !void {
    try database.lock(io);
    defer database.unlock(io);
    try records.save(database, input);
}

fn lockedEnqueue(io: Io, database: *sqlite.Database, command_id: []const u8, session_id: []const u8, kind: []const u8, document: []const u8) !void {
    try database.lock(io);
    defer database.unlock(io);
    try records.enqueueCommand(database, command_id, session_id, kind, document);
}

fn lockedFinish(io: Io, database: *sqlite.Database, command_id: []const u8, state: []const u8, failure: ?[]const u8) !void {
    try database.lock(io);
    defer database.unlock(io);
    try records.finishCommand(database, command_id, state, failure);
}

fn lockedRuntime(io: Io, database: *sqlite.Database, session_id: []const u8, status: []const u8, native_session_id: ?[]const u8, cursor: ?u64) !void {
    try database.lock(io);
    defer database.unlock(io);
    try records.updateRuntime(database, session_id, status, native_session_id, cursor);
}

fn sessionIdFromDocument(allocator: std.mem.Allocator, document: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, document, .{}) catch return error.InvalidSessionPayload;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidSessionPayload;
    const session_id = optionalString(parsed.value.object, "sessionId") orelse "default";
    if (!validSessionId(session_id)) return error.InvalidSessionId;
    return allocator.dupe(u8, session_id);
}

fn serialize(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var output: Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try std.json.Stringify.value(value, .{}, &output.writer);
    return output.toOwnedSlice();
}

fn commandId(io: Io) [32]u8 {
    var random: [16]u8 = undefined;
    io.random(&random);
    return std.fmt.bytesToHex(random, .lower);
}

fn optionalString(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    if (value != .string) return null;
    const trimmed = std.mem.trim(u8, value.string, " \t\r\n");
    return if (trimmed.len > 0) trimmed else null;
}

fn booleanField(object: std.json.ObjectMap, name: []const u8) ?bool {
    const value = object.get(name) orelse return null;
    return if (value == .bool) value.bool else null;
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

fn success(status: http.Status) bool {
    const code = @intFromEnum(status);
    return code >= 200 and code < 300;
}

fn replaceSessionStatus(session: *records.Session, status: []const u8) !void {
    const replacement = try session.allocator.dupe(u8, status);
    session.allocator.free(session.status);
    session.status = replacement;
}
