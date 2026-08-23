const std = @import("std");
const config = @import("../config.zig");
const repository = @import("../repository/agent_automations.zig");
const sqlite = @import("../repository/sqlite.zig");
const agent_coordinator = @import("agent_coordinator.zig");
const harness_runtime = @import("harness_runtime.zig");

const Io = std.Io;
const http = std.http;

pub fn listPayload(allocator: std.mem.Allocator, io: Io, database: *sqlite.Database) ![]u8 {
    try database.lock(io);
    defer database.unlock(io);
    var automations = try repository.list(allocator, database);
    defer automations.deinit();
    var output: Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"automations\":[");
    for (automations.documents, 0..) |document, index| {
        if (index > 0) try output.writer.writeByte(',');
        try output.writer.writeAll(document);
    }
    try output.writer.writeAll("]}");
    return output.toOwnedSlice();
}

pub fn createPayload(allocator: std.mem.Allocator, io: Io, database: *sqlite.Database, document: []const u8) ![]u8 {
    var body = try parseObject(allocator, document);
    defer body.deinit();
    const object = body.value.object;
    const name = requiredString(object, "name") orelse return error.AutomationNameRequired;
    const prompt = requiredString(object, "prompt") orelse return error.AutomationPromptRequired;
    const model_id = requiredString(object, "modelId") orelse return error.AutomationModelRequired;
    const cwd = requiredString(object, "cwd") orelse return error.AutomationCwdRequired;
    const schedule = object.get("schedule") orelse return error.AutomationScheduleRequired;
    try validateSchedule(schedule);
    var random: [4]u8 = undefined;
    io.random(&random);
    const suffix = std.fmt.bytesToHex(random, .lower);
    const id = try std.fmt.allocPrint(allocator, "auto-{s}", .{suffix[0..]});
    defer allocator.free(id);
    var now_buffer: [24]u8 = undefined;
    var next_buffer: [24]u8 = undefined;
    const now = formatTimestampAt(io, 0, &now_buffer);
    const next = try nextRunAt(io, schedule, &next_buffer);
    var output: Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try output.writer.writeAll("{\"version\":1,\"id\":");
    try std.json.Stringify.value(id, .{}, &output.writer);
    try output.writer.writeAll(",\"name\":");
    try std.json.Stringify.value(name, .{}, &output.writer);
    try output.writer.writeAll(",\"prompt\":");
    try std.json.Stringify.value(prompt, .{}, &output.writer);
    try output.writer.writeAll(",\"modelId\":");
    try std.json.Stringify.value(model_id, .{}, &output.writer);
    try output.writer.writeAll(",\"cwd\":");
    try std.json.Stringify.value(cwd, .{}, &output.writer);
    try writeOptional(&output.writer, "targetSessionId", optionalString(object, "targetSessionId"));
    try writeOptional(&output.writer, "nodeId", optionalString(object, "nodeId"));
    try writeOptional(&output.writer, "projectId", optionalString(object, "projectId"));
    try output.writer.writeAll(",\"harness\":\"pi\",\"schedule\":");
    try std.json.Stringify.value(schedule, .{}, &output.writer);
    try output.writer.writeAll(",\"status\":\"active\",\"nextRunAt\":");
    try std.json.Stringify.value(next, .{}, &output.writer);
    try output.writer.writeAll(",\"lastRun\":null,\"runs\":[],\"unread\":false,\"createdAt\":");
    try std.json.Stringify.value(now, .{}, &output.writer);
    try output.writer.writeAll(",\"updatedAt\":");
    try std.json.Stringify.value(now, .{}, &output.writer);
    try output.writer.writeByte('}');
    const automation = try allocator.dupe(u8, output.writer.buffered());
    defer allocator.free(automation);
    try lockedSave(io, database, id, "active", next, automation);
    return automationResponse(allocator, automation);
}

pub fn patchPayload(allocator: std.mem.Allocator, io: Io, database: *sqlite.Database, automation_id: []const u8, document: []const u8) ![]u8 {
    var body = try parseObject(allocator, document);
    defer body.deinit();
    try database.lock(io);
    defer database.unlock(io);
    const stored = (try repository.get(allocator, database, automation_id)) orelse return error.AutomationNotFound;
    defer allocator.free(stored);
    var automation = try parseObject(allocator, stored);
    defer automation.deinit();
    const fields = [_][]const u8{ "name", "prompt", "modelId", "cwd", "targetSessionId", "nodeId", "projectId", "schedule", "status", "unread" };
    for (fields) |field| if (body.value.object.get(field)) |value| {
        if ((std.mem.eql(u8, field, "name") or std.mem.eql(u8, field, "prompt") or std.mem.eql(u8, field, "modelId") or std.mem.eql(u8, field, "cwd")) and (value != .string or std.mem.trim(u8, value.string, " \t\r\n").len == 0)) return error.InvalidAutomationPayload;
        if (std.mem.eql(u8, field, "schedule")) try validateSchedule(value);
        if (std.mem.eql(u8, field, "status") and (value != .string or (!std.mem.eql(u8, value.string, "active") and !std.mem.eql(u8, value.string, "paused")))) return error.InvalidAutomationStatus;
        try automation.value.object.put(automation.arena.allocator(), field, value);
    };
    var now_buffer: [24]u8 = undefined;
    const now = formatTimestampAt(io, 0, &now_buffer);
    try automation.value.object.put(automation.arena.allocator(), "updatedAt", .{ .string = try automation.arena.allocator().dupe(u8, now) });
    const schedule = automation.value.object.get("schedule") orelse return error.InvalidAutomationRecord;
    var next_buffer: [24]u8 = undefined;
    const next = if (std.mem.eql(u8, optionalString(automation.value.object, "status") orelse "active", "active")) try nextRunAt(io, schedule, &next_buffer) else null;
    try automation.value.object.put(automation.arena.allocator(), "nextRunAt", if (next) |value| .{ .string = try automation.arena.allocator().dupe(u8, value) } else .null);
    const updated = try serialize(allocator, automation.value);
    defer allocator.free(updated);
    try repository.save(database, automation_id, optionalString(automation.value.object, "status") orelse "active", next, updated);
    return automationResponse(allocator, updated);
}

pub fn deletePayload(allocator: std.mem.Allocator, io: Io, database: *sqlite.Database, automation_id: []const u8) ![]u8 {
    try database.lock(io);
    defer database.unlock(io);
    if (!try repository.delete(database, automation_id)) return error.AutomationNotFound;
    return allocator.dupe(u8, "{\"success\":true}");
}

pub fn runPayload(allocator: std.mem.Allocator, io: Io, mode: config.Mode, client: *http.Client, database: *sqlite.Database, harness: *harness_runtime.Manager, automation_id: []const u8) ![]u8 {
    const stored = try lockedGet(allocator, io, database, automation_id) orelse return error.AutomationNotFound;
    defer allocator.free(stored);
    var automation = try parseObject(allocator, stored);
    defer automation.deinit();
    const object = automation.value.object;
    const prompt = requiredString(object, "prompt") orelse return error.InvalidAutomationRecord;
    const model_id = requiredString(object, "modelId") orelse return error.InvalidAutomationRecord;
    const cwd = requiredString(object, "cwd") orelse return error.InvalidAutomationRecord;
    const target_session = optionalString(object, "targetSessionId");
    const node_id = optionalString(object, "nodeId");
    const project_id = optionalString(object, "projectId");
    var random: [8]u8 = undefined;
    io.random(&random);
    const suffix = std.fmt.bytesToHex(random, .lower);
    const session_id = try std.fmt.allocPrint(allocator, "automation:{s}:{s}", .{ automation_id, suffix[0..] });
    defer allocator.free(session_id);
    const turn = try turnDocument(allocator, session_id, model_id, prompt, cwd, target_session, node_id, project_id);
    defer allocator.free(turn);
    var run_error: ?[]const u8 = null;
    const response = agent_coordinator.turnPayload(allocator, io, mode, client, database, harness, turn) catch |failure| failed: {
        run_error = @errorName(failure);
        break :failed null;
    };
    defer if (response) |value| allocator.free(value);
    var result: ?RunResult = null;
    defer if (result) |*value| value.deinit();
    if (response != null) result = waitForRun(allocator, io, mode, client, database, harness, session_id) catch |failure| failed: {
        run_error = @errorName(failure);
        break :failed null;
    };
    var at_buffer: [24]u8 = undefined;
    const at = formatTimestampAt(io, 0, &at_buffer);
    const completed_error = if (result) |value| value.failure else run_error;
    const updated = try recordRun(allocator, io, &automation, at, cwd, if (result) |value| value.native_session else target_session, project_id, if (result) |value| value.summary else "", completed_error);
    defer allocator.free(updated);
    const status = optionalString(automation.value.object, "status") orelse "active";
    const next = nullableStringValue(automation.value.object.get("nextRunAt"));
    try lockedSave(io, database, automation_id, status, next, updated);
    var output: Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.print("{{\"ok\":true,\"started\":{},\"automation\":{s}}}", .{ response != null, updated });
    return output.toOwnedSlice();
}

pub fn runScheduler(allocator: std.mem.Allocator, io: Io, mode: config.Mode, client: *http.Client, database: *sqlite.Database, harness: *harness_runtime.Manager) Io.Cancelable!void {
    while (true) {
        runDue(allocator, io, mode, client, database, harness) catch |failure| std.log.err("automation scheduler pass failed: {t}", .{failure});
        try io.sleep(.fromSeconds(30), .awake);
    }
}

fn runDue(allocator: std.mem.Allocator, io: Io, mode: config.Mode, client: *http.Client, database: *sqlite.Database, harness: *harness_runtime.Manager) !void {
    var now_buffer: [24]u8 = undefined;
    const now = formatTimestampAt(io, 0, &now_buffer);
    try database.lock(io);
    var due = repository.due(allocator, database, now) catch |failure| {
        database.unlock(io);
        return failure;
    };
    database.unlock(io);
    defer due.deinit();
    for (due.documents) |document| {
        var parsed = parseObject(allocator, document) catch |failure| {
            std.log.err("invalid due automation: {t}", .{failure});
            continue;
        };
        defer parsed.deinit();
        const automation_id = requiredString(parsed.value.object, "id") orelse {
            std.log.err("due automation is missing id", .{});
            continue;
        };
        const response = runPayload(allocator, io, mode, client, database, harness, automation_id) catch |failure| {
            std.log.err("automation {s} dispatch failed: {t}", .{ automation_id, failure });
            continue;
        };
        allocator.free(response);
    }
}

const RunResult = struct {
    allocator: std.mem.Allocator,
    native_session: ?[]u8,
    summary: []u8,
    failure: ?[]u8,

    fn deinit(result: *RunResult) void {
        if (result.native_session) |value| result.allocator.free(value);
        result.allocator.free(result.summary);
        if (result.failure) |value| result.allocator.free(value);
        result.* = undefined;
    }
};

fn waitForRun(allocator: std.mem.Allocator, io: Io, mode: config.Mode, client: *http.Client, database: *sqlite.Database, harness: *harness_runtime.Manager, session_id: []const u8) !RunResult {
    var cursor: u64 = 0;
    var native_session: ?[]u8 = null;
    errdefer if (native_session) |value| allocator.free(value);
    var attempts: usize = 0;
    while (attempts < 14_400) : (attempts += 1) {
        try io.sleep(.fromMilliseconds(250), .awake);
        const payload = try agent_coordinator.statusPayload(allocator, io, mode, client, database, harness, session_id, cursor);
        defer allocator.free(payload);
        var status = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch return error.InvalidHarnessResponse;
        defer status.deinit();
        if (status.value != .object) return error.InvalidHarnessResponse;
        const state = status.value.object.get("status") orelse return error.InvalidHarnessResponse;
        if (state != .object) return error.InvalidHarnessResponse;
        if (native_session == null) {
            if (optionalString(state.object, "nativeSessionId") orelse optionalString(state.object, "piSessionId")) |value| native_session = try allocator.dupe(u8, value);
        }
        if (optionalString(state.object, "lastError")) |failure| return .{
            .allocator = allocator,
            .native_session = native_session,
            .summary = try allocator.dupe(u8, ""),
            .failure = try allocator.dupe(u8, failure),
        };
        var settled = false;
        if (status.value.object.get("events")) |events| if (events == .array) for (events.array.items) |event| {
            if (event != .object) continue;
            cursor = @max(cursor, unsignedField(event.object, "seq") orelse 0);
            const native = event.object.get("event") orelse continue;
            if (native == .object and std.mem.eql(u8, optionalString(native.object, "type") orelse "", "agent_settled")) settled = true;
        };
        if (!settled) continue;
        const transcript = try agent_coordinator.transcriptPayload(allocator, io, mode, client, database, harness, session_id, null);
        defer allocator.free(transcript);
        var assistant = try lastAssistantResult(allocator, transcript);
        errdefer assistant.deinit();
        if (native_session) |value| {
            if (assistant.native_session) |previous| allocator.free(previous);
            assistant.native_session = value;
            native_session = null;
        }
        return assistant;
    }
    return error.AutomationRunTimeout;
}

fn lastAssistantResult(allocator: std.mem.Allocator, document: []const u8) !RunResult {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, document, .{}) catch return error.InvalidHarnessResponse;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidHarnessResponse;
    const entries = parsed.value.object.get("entries") orelse return error.InvalidHarnessResponse;
    if (entries != .array) return error.InvalidHarnessResponse;
    var summary = try allocator.dupe(u8, "");
    errdefer allocator.free(summary);
    var failure: ?[]u8 = null;
    errdefer if (failure) |value| allocator.free(value);
    for (entries.array.items) |entry| {
        if (entry != .object or !std.mem.eql(u8, optionalString(entry.object, "type") orelse "", "message")) continue;
        const message = entry.object.get("message") orelse continue;
        if (message != .object or !std.mem.eql(u8, optionalString(message.object, "role") orelse "", "assistant")) continue;
        const text = try messageText(allocator, message.object.get("content"));
        defer allocator.free(text);
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len > 0) {
            allocator.free(summary);
            summary = try allocator.dupe(u8, trimmed[0..@min(trimmed.len, 2000)]);
            if (failure) |value| allocator.free(value);
            failure = null;
        } else if (optionalString(message.object, "errorMessage")) |value| {
            if (failure) |previous| allocator.free(previous);
            failure = try allocator.dupe(u8, value);
        }
    }
    if (summary.len == 0 and failure == null) failure = try allocator.dupe(u8, "Automation completed without an assistant response.");
    const native = if (optionalString(parsed.value.object, "nativeSessionId")) |value| try allocator.dupe(u8, value) else null;
    return .{ .allocator = allocator, .native_session = native, .summary = summary, .failure = failure };
}

fn messageText(allocator: std.mem.Allocator, content: ?std.json.Value) ![]u8 {
    const value = content orelse return allocator.dupe(u8, "");
    if (value == .string) return allocator.dupe(u8, value.string);
    if (value != .array) return allocator.dupe(u8, "");
    var output: Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    for (value.array.items) |block| {
        if (block != .object or !std.mem.eql(u8, optionalString(block.object, "type") orelse "", "text")) continue;
        if (optionalString(block.object, "text")) |text| try output.writer.writeAll(text);
    }
    return output.toOwnedSlice();
}

fn recordRun(allocator: std.mem.Allocator, io: Io, automation: *std.json.Parsed(std.json.Value), at: []const u8, cwd: []const u8, native_session: ?[]const u8, project_id: ?[]const u8, summary: []const u8, failure: ?[]const u8) ![]u8 {
    const arena = automation.arena.allocator();
    var run: std.json.ObjectMap = .empty;
    try run.put(arena, "at", .{ .string = try arena.dupe(u8, at) });
    try run.put(arena, "piSessionId", if (native_session) |value| .{ .string = value } else .null);
    try run.put(arena, "cwd", .{ .string = cwd });
    try run.put(arena, "projectId", if (project_id) |value| .{ .string = value } else .null);
    try run.put(arena, "outcome", .{ .string = if (failure == null) "ok" else "error" });
    try run.put(arena, "summary", .{ .string = try arena.dupe(u8, summary) });
    if (failure) |value| try run.put(arena, "error", .{ .string = value });
    const run_value: std.json.Value = .{ .object = run };
    try automation.value.object.put(arena, "lastRun", run_value);
    const current = automation.value.object.get("runs");
    var runs: std.json.Array = .init(arena);
    try runs.append(run_value);
    if (current) |value| if (value == .array) for (value.array.items[0..@min(value.array.items.len, 19)]) |entry| try runs.append(entry);
    try automation.value.object.put(arena, "runs", .{ .array = runs });
    try automation.value.object.put(arena, "unread", .{ .bool = true });
    var next_buffer: [24]u8 = undefined;
    const schedule = automation.value.object.get("schedule") orelse return error.InvalidAutomationRecord;
    const next = try nextRunAt(io, schedule, &next_buffer);
    try automation.value.object.put(arena, "nextRunAt", .{ .string = try arena.dupe(u8, next) });
    try automation.value.object.put(arena, "updatedAt", .{ .string = try arena.dupe(u8, at) });
    return serialize(allocator, automation.value);
}

fn turnDocument(allocator: std.mem.Allocator, session_id: []const u8, model_id: []const u8, prompt: []const u8, cwd: []const u8, native_session: ?[]const u8, node_id: ?[]const u8, project_id: ?[]const u8) ![]u8 {
    var output: Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"sessionId\":");
    try std.json.Stringify.value(session_id, .{}, &output.writer);
    try output.writer.writeAll(",\"modelId\":");
    try std.json.Stringify.value(model_id, .{}, &output.writer);
    try output.writer.writeAll(",\"message\":");
    try std.json.Stringify.value(prompt, .{}, &output.writer);
    try output.writer.writeAll(",\"cwd\":");
    try std.json.Stringify.value(cwd, .{}, &output.writer);
    try writeOptional(&output.writer, "piSessionId", native_session);
    try writeOptional(&output.writer, "nodeId", node_id);
    try writeOptional(&output.writer, "projectId", project_id);
    try output.writer.writeAll(",\"toolAccess\":\"full\",\"mode\":\"prompt\"}");
    return output.toOwnedSlice();
}

fn validateSchedule(value: std.json.Value) !void {
    if (value != .object) return error.InvalidAutomationSchedule;
    const kind = requiredString(value.object, "kind") orelse return error.InvalidAutomationSchedule;
    if (std.mem.eql(u8, kind, "interval")) {
        const minutes = unsignedField(value.object, "minutes") orelse return error.InvalidAutomationSchedule;
        if (minutes < 1 or minutes > 525_600) return error.InvalidAutomationSchedule;
        return;
    }
    if (std.mem.eql(u8, kind, "daily")) return validateTime(requiredString(value.object, "time") orelse return error.InvalidAutomationSchedule);
    if (std.mem.eql(u8, kind, "weekly")) {
        const day = unsignedField(value.object, "day") orelse return error.InvalidAutomationSchedule;
        if (day > 6) return error.InvalidAutomationSchedule;
        return validateTime(requiredString(value.object, "time") orelse return error.InvalidAutomationSchedule);
    }
    return error.InvalidAutomationSchedule;
}

fn nextRunAt(io: Io, schedule: std.json.Value, buffer: *[24]u8) ![]const u8 {
    const now = @max(Io.Clock.real.now(io).toSeconds(), 0);
    const kind = requiredString(schedule.object, "kind") orelse return error.InvalidAutomationSchedule;
    if (std.mem.eql(u8, kind, "interval")) return formatTimestampSeconds(now + @as(i64, @intCast(unsignedField(schedule.object, "minutes").? * 60)), buffer);
    const target_seconds = try timeSeconds(requiredString(schedule.object, "time").?);
    const day_start = now - @mod(now, 86_400);
    if (std.mem.eql(u8, kind, "daily")) {
        var candidate = day_start + target_seconds;
        if (candidate <= now) candidate += 86_400;
        if (booleanField(schedule.object, "weekdaysOnly") orelse false) {
            while (weekday(candidate) == 0 or weekday(candidate) == 6) candidate += 86_400;
        }
        return formatTimestampSeconds(candidate, buffer);
    }
    const target_day = unsignedField(schedule.object, "day").?;
    var candidate = day_start + target_seconds;
    while (weekday(candidate) != target_day or candidate <= now) candidate += 86_400;
    return formatTimestampSeconds(candidate, buffer);
}

fn validateTime(value: []const u8) !void {
    _ = try timeSeconds(value);
}

fn timeSeconds(value: []const u8) !i64 {
    if (value.len != 5 or value[2] != ':') return error.InvalidAutomationSchedule;
    const hour = std.fmt.parseInt(u8, value[0..2], 10) catch return error.InvalidAutomationSchedule;
    const minute = std.fmt.parseInt(u8, value[3..5], 10) catch return error.InvalidAutomationSchedule;
    if (hour > 23 or minute > 59) return error.InvalidAutomationSchedule;
    return @as(i64, hour) * 3600 + @as(i64, minute) * 60;
}

fn weekday(seconds: i64) u64 {
    return @intCast(@mod(@divFloor(seconds, 86_400) + 4, 7));
}

fn lockedGet(allocator: std.mem.Allocator, io: Io, database: *sqlite.Database, id: []const u8) !?[]u8 {
    try database.lock(io);
    defer database.unlock(io);
    return repository.get(allocator, database, id);
}

fn lockedSave(io: Io, database: *sqlite.Database, id: []const u8, status: []const u8, next: ?[]const u8, document: []const u8) !void {
    try database.lock(io);
    defer database.unlock(io);
    try repository.save(database, id, status, next, document);
}

fn automationResponse(allocator: std.mem.Allocator, automation: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{{\"automation\":{s}}}", .{automation});
}

fn parseObject(allocator: std.mem.Allocator, document: []const u8) !std.json.Parsed(std.json.Value) {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, document, .{}) catch return error.InvalidAutomationPayload;
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.InvalidAutomationPayload;
    return parsed;
}

fn requiredString(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    return optionalString(object, name);
}

fn optionalString(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    if (value != .string) return null;
    const trimmed = std.mem.trim(u8, value.string, " \t\r\n");
    return if (trimmed.len > 0) trimmed else null;
}

fn nullableStringValue(value: ?std.json.Value) ?[]const u8 {
    const present = value orelse return null;
    return if (present == .string) present.string else null;
}

fn unsignedField(object: std.json.ObjectMap, name: []const u8) ?u64 {
    const value = object.get(name) orelse return null;
    if (value != .integer or value.integer < 0) return null;
    return @intCast(value.integer);
}

fn booleanField(object: std.json.ObjectMap, name: []const u8) ?bool {
    const value = object.get(name) orelse return null;
    return if (value == .bool) value.bool else null;
}

fn writeOptional(writer: *Io.Writer, name: []const u8, value: ?[]const u8) !void {
    try writer.writeByte(',');
    try std.json.Stringify.value(name, .{}, writer);
    try writer.writeByte(':');
    if (value) |text| try std.json.Stringify.value(text, .{}, writer) else try writer.writeAll("null");
}

fn serialize(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var output: Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try std.json.Stringify.value(value, .{}, &output.writer);
    return output.toOwnedSlice();
}

fn formatTimestampAt(io: Io, offset_seconds: i64, buffer: *[24]u8) []const u8 {
    return formatTimestampSeconds(@max(Io.Clock.real.now(io).toSeconds() + offset_seconds, 0), buffer);
}

fn formatTimestampSeconds(seconds: i64, buffer: *[24]u8) []const u8 {
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(seconds) };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.000Z", .{
        year_day.year, month_day.month.numeric(), month_day.day_index + 1,
        day_seconds.getHoursIntoDay(), day_seconds.getMinutesIntoHour(), day_seconds.getSecondsIntoMinute(),
    }) catch unreachable;
}
