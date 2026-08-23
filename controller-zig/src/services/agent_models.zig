const std = @import("std");
const config = @import("../config.zig");
const head_connections = @import("../repository/head_connection.zig");

const Io = std.Io;
const http = std.http;
const max_response_bytes = 16 * 1024 * 1024;
const request_timeout = Io.Duration.fromMilliseconds(2500);

const FetchResult = struct {
    status: http.Status,
    body: []u8,
};

pub fn payload(allocator: std.mem.Allocator, io: Io, configuration: *const config.Config, client: *http.Client) ![]u8 {
    var connection = if (configuration.mode == .standalone) try head_connections.load(allocator, io, configuration.data_dir) else null;
    defer if (connection) |*value| value.deinit();
    const base_url = if (connection) |value| value.url else try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{configuration.port});
    defer if (connection == null) allocator.free(base_url);
    const api_key = if (connection) |value| value.api_key else configuration.api_key orelse "local-studio";
    const url = try std.fmt.allocPrint(allocator, "{s}/v1/models", .{base_url});
    defer allocator.free(url);
    const fetched = try fetchWithTimeout(allocator, io, client, url, api_key);
    defer allocator.free(fetched.body);
    if (fetched.status.class() != .success) return error.AgentModelCatalogRejected;
    return normalizeCatalog(allocator, fetched.body, base_url);
}

fn normalizeCatalog(allocator: std.mem.Allocator, document: []const u8, controller_url: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, document, .{}) catch return error.InvalidAgentModelCatalog;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidAgentModelCatalog;
    const data = parsed.value.object.get("data") orelse return error.InvalidAgentModelCatalog;
    if (data != .array) return error.InvalidAgentModelCatalog;
    var output: Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"provider\":\"local-studio\",\"models\":[");
    var wrote = false;
    for (data.array.items) |model| {
        if (model != .object) continue;
        const id = stringField(model.object, "id") orelse continue;
        const metadata = if (model.object.get("metadata")) |value| if (value == .object) value.object else null else null;
        const name = stringField(model.object, "name") orelse if (metadata) |value| stringField(value, "name") orelse id else id;
        const context_window = firstPositive(&.{ model.object.get("contextWindow"), model.object.get("context_window"), model.object.get("max_model_len"), if (metadata) |value| value.get("contextWindow") else null, if (metadata) |value| value.get("context_window") else null }, 128_000);
        const max_tokens = firstPositive(&.{ model.object.get("maxTokens"), model.object.get("max_tokens"), if (metadata) |value| value.get("maxTokens") else null, if (metadata) |value| value.get("max_tokens") else null }, @min(context_window, 65_536));
        const reasoning = explicitBool(model.object.get("reasoning")) orelse if (metadata) |value| explicitBool(value.get("reasoning")) orelse inferReasoning(id) else inferReasoning(id);
        const vision = inferVision(model.object, metadata, id);
        const active = explicitBool(model.object.get("active")) orelse if (metadata) |value| explicitBool(value.get("active")) orelse false else false;
        if (wrote) try output.writer.writeByte(',');
        wrote = true;
        try output.writer.writeAll("{\"id\":");
        try std.json.Stringify.value(id, .{}, &output.writer);
        try output.writer.writeAll(",\"name\":");
        try std.json.Stringify.value(name, .{}, &output.writer);
        try output.writer.writeAll(",\"provider\":\"local-studio\",\"providerId\":\"local-studio\",\"rawId\":");
        try std.json.Stringify.value(id, .{}, &output.writer);
        try output.writer.writeAll(",\"controllerUrl\":");
        try std.json.Stringify.value(controller_url, .{}, &output.writer);
        try output.writer.print(",\"contextWindow\":{d},\"maxTokens\":{d},\"reasoning\":{},\"thinkingLevels\":", .{ context_window, max_tokens, reasoning });
        try writeThinkingLevels(&output.writer, reasoning);
        try output.writer.print(",\"vision\":{},\"active\":{}", .{ vision, active });
        if (metadata) |value| if (stringField(value, "api")) |api| if (std.mem.eql(u8, api, "openai-responses") or std.mem.eql(u8, api, "openai-completions")) {
            try output.writer.writeAll(",\"api\":");
            try std.json.Stringify.value(api, .{}, &output.writer);
        };
        try output.writer.writeByte('}');
    }
    try output.writer.writeAll("]}");
    return output.toOwnedSlice();
}

fn fetchWithTimeout(allocator: std.mem.Allocator, io: Io, client: *http.Client, url: []const u8, api_key: []const u8) !FetchResult {
    const Selection = union(enum) { request: anyerror!FetchResult, timer: Io.Cancelable!void };
    var selections: [2]Selection = undefined;
    var select = Io.Select(Selection).init(io, &selections);
    try select.concurrent(.request, fetch, .{ allocator, client, url, api_key });
    select.concurrent(.timer, waitForTimeout, .{io}) catch {
        while (select.cancel()) |pending| deinitSelection(allocator, pending);
        return error.ConcurrencyUnavailable;
    };
    const selected = try select.await();
    switch (selected) {
        .request => |result| {
            select.cancelDiscard();
            return try result;
        },
        .timer => |result| {
            result catch |failure| switch (failure) {
                error.Canceled => return error.Canceled,
            };
            while (select.cancel()) |pending| deinitSelection(allocator, pending);
            return error.AgentModelCatalogTimeout;
        },
    }
}

fn fetch(allocator: std.mem.Allocator, client: *http.Client, url: []const u8, api_key: []const u8) !FetchResult {
    const storage = try allocator.alloc(u8, max_response_bytes);
    defer allocator.free(storage);
    const authorization = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    defer allocator.free(authorization);
    var body: Io.Writer = .fixed(storage);
    const response = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .redirect_behavior = .unhandled,
        .keep_alive = false,
        .headers = .{ .accept_encoding = .omit },
        .extra_headers = &.{.{ .name = "Authorization", .value = authorization }},
        .response_writer = &body,
    });
    return .{ .status = response.status, .body = try allocator.dupe(u8, body.buffered()) };
}

fn waitForTimeout(io: Io) Io.Cancelable!void {
    return io.sleep(request_timeout, .awake);
}

fn deinitSelection(allocator: std.mem.Allocator, selection: anytype) void {
    switch (selection) {
        .request => |result| if (result) |response| allocator.free(response.body) else |_| {},
        .timer => {},
    }
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    if (value != .string) return null;
    const trimmed = std.mem.trim(u8, value.string, " \t\r\n");
    return if (trimmed.len > 0) trimmed else null;
}

fn firstPositive(values: []const ?std.json.Value, fallback: u64) u64 {
    for (values) |value| if (positive(value)) |number| return number;
    return fallback;
}

fn positive(value: ?std.json.Value) ?u64 {
    const present = value orelse return null;
    const number: i64 = switch (present) {
        .integer => |integer| integer,
        .float => |float| @intFromFloat(float),
        .number_string => |text| std.fmt.parseInt(i64, text, 10) catch return null,
        else => return null,
    };
    return if (number > 0) @intCast(number) else null;
}

fn explicitBool(value: ?std.json.Value) ?bool {
    const present = value orelse return null;
    return if (present == .bool) present.bool else null;
}

fn inferReasoning(id: []const u8) bool {
    for ([_][]const u8{ "reason", "thinking", "r1", "deepseek", "qwen3", "glm-5", "mimo", "inkling" }) |needle| if (std.ascii.indexOfIgnoreCase(id, needle) != null) return true;
    return false;
}

fn inferVision(object: std.json.ObjectMap, metadata: ?std.json.ObjectMap, id: []const u8) bool {
    if (metadata) |value| if (explicitBool(value.get("vision"))) |vision| return vision;
    for ([_][]const u8{ "vision", "vl", "gpt-4o", "gemini", "claude" }) |needle| if (std.ascii.indexOfIgnoreCase(id, needle) != null) return true;
    for ([_][]const u8{ "input", "inputs", "modalities" }) |name| if (object.get(name)) |value| if (value == .array) for (value.array.items) |entry| if (entry == .string and std.ascii.eqlIgnoreCase(entry.string, "image")) return true;
    return false;
}

fn writeThinkingLevels(writer: *Io.Writer, reasoning: bool) !void {
    if (reasoning) try writer.writeAll("[\"auto\",\"low\",\"medium\",\"high\",\"max\",\"off\"]") else try writer.writeAll("[\"off\"]");
}
