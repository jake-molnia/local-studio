const std = @import("std");
const io_mod = @import(".managed/fx/src/core/shared/io.zig");
const stream_provider = @import(".managed/fx/src/core/agent/stream_provider.zig");
const types = @import(".managed/fx/src/core/shared/types.zig");
const openai_codex = @import(".managed/fx/src/gateway/openai_codex.zig");
const responses_protocol = @import(".managed/fx/src/gateway/responses_protocol.zig");
const mcp_bridge = @import("mcp_bridge");

const system_prompt =
    "You are the built-in Local Studio Chat assistant. You have no filesystem, terminal, shell, or git access. " ++
    "Use the available browser and connector tools whenever they help, continue after each tool result until the request is complete, and state clearly when a filesystem-bound capability blocks the request.";
const max_error_body_bytes = 1024 * 1024;
const max_sse_line_bytes = 32 * 1024 * 1024;
const max_sse_aggregate_bytes = 64 * 1024 * 1024;
const max_sse_events = 100_000;
const max_tool_calls = 128;
const max_tool_identity_bytes = 1024;
const max_tool_arguments_bytes = 4 * 1024 * 1024;
const max_provider_state_bytes = 4 * 1024 * 1024;
const max_chat_tool_rounds = 16;
const max_chat_tools = 512;
const max_chat_tool_result_bytes = 2 * 1024 * 1024;

var gateway_client: ?std.http.Client = null;

const ChatHistoryEntry = struct {
    role: types.ChatRole,
    content: []u8,

    fn deinit(entry: *ChatHistoryEntry, allocator: std.mem.Allocator) void {
        allocator.free(entry.content);
        entry.* = undefined;
    }
};

const ChatToolCatalog = struct {
    allocator: std.mem.Allocator,
    parsed: std.json.Parsed(std.json.Value),
    tools: []stream_provider.DynamicFunctionTool,

    fn deinit(catalog: *ChatToolCatalog) void {
        catalog.allocator.free(catalog.tools);
        catalog.parsed.deinit();
        catalog.* = undefined;
    }

    fn contains(catalog: *const ChatToolCatalog, name: []const u8) bool {
        for (catalog.tools) |tool| if (std.mem.eql(u8, tool.name, name)) return true;
        return false;
    }
};

const BridgeConfig = struct {
    base_url: []const u8,
    api_key: ?[]const u8,
    model_id: []const u8,
    session_id: []const u8,
};

const ChatToolResult = struct {
    text: []u8,
    is_error: bool,

    fn deinit(result: *ChatToolResult, allocator: std.mem.Allocator) void {
        allocator.free(result.text);
        result.* = undefined;
    }
};

const ChatOutput = struct {
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    content: std.ArrayList(u8) = .empty,
    failed: bool = false,

    fn deinit(output: *ChatOutput) void {
        output.content.deinit(output.allocator);
    }

    fn emit(raw: *anyopaque, event: stream_provider.Event) void {
        const output: *ChatOutput = @ptrCast(@alignCast(raw));
        switch (event) {
            .content_delta => |chunk| {
                output.content.appendSlice(output.allocator, chunk) catch {
                    output.failed = true;
                    return;
                };
                output.writeDelta("text_delta", chunk) catch {
                    output.failed = true;
                };
            },
            .reasoning_delta => |chunk| output.writeDelta("thinking_delta", chunk) catch {
                output.failed = true;
            },
            else => {},
        }
    }

    fn writeDelta(output: *ChatOutput, event_type: []const u8, chunk: []const u8) !void {
        try output.writer.writeAll("{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":");
        try std.json.Stringify.value(event_type, .{}, output.writer);
        try output.writer.writeAll(",\"delta\":");
        try std.json.Stringify.value(chunk, .{}, output.writer);
        try output.writer.writeAll("}}\n");
        try output.writer.flush();
    }

    fn writeToolCall(output: *ChatOutput, call: types.ToolCall) !void {
        try output.writer.writeAll("{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"toolcall_end\",\"toolCall\":{\"id\":");
        try std.json.Stringify.value(call.id, .{}, output.writer);
        try output.writer.writeAll(",\"name\":");
        try std.json.Stringify.value(call.name, .{}, output.writer);
        try output.writer.writeAll(",\"arguments\":");
        try output.writer.writeAll(call.arguments_json);
        try output.writer.writeAll("}}}\n");
        try output.writer.flush();
    }

    fn writeToolResult(output: *ChatOutput, call: types.ToolCall, result: ChatToolResult) !void {
        try output.writer.writeAll("{\"type\":\"tool_execution_end\",\"toolCallId\":");
        try std.json.Stringify.value(call.id, .{}, output.writer);
        try output.writer.print(",\"isError\":{},\"result\":{{\"content\":[{{\"type\":\"text\",\"text\":", .{result.is_error});
        try std.json.Stringify.value(result.text, .{}, output.writer);
        try output.writer.writeAll("}]}}\n");
        try output.writer.flush();
    }
};

pub fn runChat(init: std.process.Init) !void {
    io_mod.setIo(init.io);
    io_mod.setEnvironMap(init.environ_map);
    gateway_client = .{ .allocator = init.gpa, .io = init.io };
    defer {
        gateway_client.?.deinit();
        gateway_client = null;
    }
    const api_key = firstEnvironment(init.environ_map, &.{ "LOCAL_STUDIO_FX_API_KEY", "AI_GATEWAY_API_KEY" }) orelse return error.FxCredentialRequired;
    const model = firstEnvironment(init.environ_map, &.{ "LOCAL_STUDIO_FX_MODEL", "FX_MODEL" }) orelse return error.FxModelRequired;
    _ = firstEnvironment(init.environ_map, &.{ "LOCAL_STUDIO_FX_GATEWAY_URL", "FX_GATEWAY_CHAT_URL" }) orelse return error.FxGatewayRequired;
    const home = firstEnvironment(init.environ_map, &.{"LOCAL_STUDIO_FX_HOME"}) orelse return error.FxHomeRequired;
    const native_id = firstEnvironment(init.environ_map, &.{"LOCAL_STUDIO_CHAT_SESSION_ID"}) orelse return error.FxSessionRequired;
    const bridge = BridgeConfig{
        .base_url = firstEnvironment(init.environ_map, &.{"LOCAL_STUDIO_MCP_BRIDGE_URL"}) orelse return error.BridgeUrlRequired,
        .api_key = firstEnvironment(init.environ_map, &.{"LOCAL_STUDIO_MCP_BRIDGE_KEY"}),
        .model_id = firstEnvironment(init.environ_map, &.{"LOCAL_STUDIO_MCP_BRIDGE_MODEL"}) orelse model,
        .session_id = firstEnvironment(init.environ_map, &.{"LOCAL_STUDIO_MCP_BRIDGE_SESSION"}) orelse native_id,
    };
    const sessions_dir = try std.fs.path.join(init.gpa, &.{ home, "sessions" });
    defer init.gpa.free(sessions_dir);
    _ = try std.Io.Dir.cwd().createDirPathStatus(init.io, sessions_dir, @enumFromInt(0o700));
    const history_filename = try std.fmt.allocPrint(init.gpa, "{s}.json", .{native_id});
    defer init.gpa.free(history_filename);
    const history_path = try std.fs.path.join(init.gpa, &.{ sessions_dir, history_filename });
    defer init.gpa.free(history_path);
    var history = try loadChatHistory(init.gpa, init.io, history_path);
    defer {
        for (history.items) |*entry| entry.deinit(init.gpa);
        history.deinit(init.gpa);
    }
    var input_buffer: [64 * 1024]u8 = undefined;
    var output_buffer: [64 * 1024]u8 = undefined;
    var input = std.Io.File.stdin().reader(init.io, &input_buffer);
    var output = std.Io.File.stdout().writer(init.io, &output_buffer);
    while (try input.interface.takeDelimiter('\n')) |line_value| {
        const line = std.mem.trim(u8, line_value, " \t\r");
        if (line.len == 0) continue;
        try runChatTurn(init.gpa, init.io, api_key, model, bridge, history_path, &history, &output.interface, line);
    }
}

fn runChatTurn(allocator: std.mem.Allocator, io: std.Io, api_key: []const u8, model: []const u8, bridge: BridgeConfig, history_path: []const u8, history: *std.ArrayList(ChatHistoryEntry), writer: *std.Io.Writer, document: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, document, .{}) catch return writeChatError(writer, "Invalid Chat request");
    defer parsed.deinit();
    if (parsed.value != .object) return writeChatError(writer, "Invalid Chat request");
    const message = jsonString(parsed.value.object, "message") orelse return writeChatError(writer, "Chat message is required");
    const thinking = jsonString(parsed.value.object, "thinkingLevel");
    const browser_enabled = jsonBool(parsed.value.object, "browserToolEnabled") orelse false;
    var catalog = loadChatToolCatalog(allocator, io, bridge, browser_enabled) catch |failure| {
        try writeChatError(writer, @errorName(failure));
        return;
    };
    defer catalog.deinit();
    try history.append(allocator, .{ .role = .user, .content = try allocator.dupe(u8, message) });
    var keep_user = false;
    defer if (!keep_user) {
        var removed = history.pop().?;
        removed.deinit(allocator);
    };
    var messages: std.ArrayList(types.ChatMessage) = .empty;
    defer messages.deinit(allocator);
    try messages.append(allocator, .{ .role = .system, .content = system_prompt });
    for (history.items) |entry| try messages.append(allocator, .{ .role = entry.role, .content = entry.content });
    var chat_output = ChatOutput{ .allocator = allocator, .writer = writer };
    defer chat_output.deinit();
    var delivery = stream_provider.DeliveryCertainty.init();
    var attempt_evidence: stream_provider.AttemptEvidence = .{};
    var cancelled = std.atomic.Value(bool).init(false);
    const effort = if (thinking) |value| if (!std.mem.eql(u8, value, "off")) types.ReasoningEffort.parse(value) else null else null;
    var turn_arena = std.heap.ArenaAllocator.init(allocator);
    defer turn_arena.deinit();
    const turn_allocator = turn_arena.allocator();
    var assistant: []const u8 = "";
    var round: usize = 0;
    while (round < max_chat_tool_rounds) : (round += 1) {
        delivery = stream_provider.DeliveryCertainty.init();
        attempt_evidence = .{};
        var result = streamCompletion(null, allocator, .{
            .credential = .{ .secret = api_key },
            .session_id = null,
            .model = model,
            .retry_count = 0,
            .messages = messages.items,
            .tools = .{ .selected_dynamic = catalog.tools },
            .tool_choice = if (catalog.tools.len > 0) .auto else .none,
            .vision_mode = .unavailable,
            .provider_options = .{ .reasoning = if (effort) |value| if (!value.isDefault()) value else null else null },
            .trace_ctx = .{},
            .content_capture_limit = max_sse_aggregate_bytes,
            .delivery = &delivery,
            .attempt_evidence = &attempt_evidence,
            .events = .{ .context = &chat_output, .emit_fn = ChatOutput.emit },
            .admission = .{ .context = &chat_output, .admit_fn = admitChat },
            .cancel_flag = &cancelled,
        }) catch |failure| {
            try writeChatError(writer, @errorName(failure));
            return;
        };
        defer result.deinit(allocator);
        if (chat_output.failed) return writeChatError(writer, "Chat stream could not be delivered");
        const completion = switch (result) {
            .completed => |completed| completed.completion,
            .failed => |failure| {
                try writeChatError(writer, failure.detail orelse @tagName(failure.kind));
                return;
            },
        };
        if (completion.tool_calls.len == 0) {
            assistant = if (chat_output.content.items.len > 0)
                chat_output.content.items
            else if (completion.content) |value|
                try turn_allocator.dupe(u8, value)
            else
                "";
            break;
        }
        const calls = try duplicateToolCalls(turn_allocator, completion.tool_calls);
        try messages.append(allocator, .{
            .role = .assistant,
            .content = if (completion.content) |value| try turn_allocator.dupe(u8, value) else null,
            .tool_calls = calls,
            .provider_state_json = if (completion.provider_state_json) |value| try turn_allocator.dupe(u8, value) else null,
        });
        for (calls) |call| {
            try chat_output.writeToolCall(call);
            var tool_result = try callChatTool(allocator, io, bridge, &catalog, call);
            defer tool_result.deinit(allocator);
            try chat_output.writeToolResult(call, tool_result);
            try messages.append(allocator, .{
                .role = .tool,
                .content = try turn_allocator.dupe(u8, tool_result.text),
                .tool_call_id = call.id,
                .tool_name = call.name,
            });
        }
    }
    if (round == max_chat_tool_rounds) return writeChatError(writer, "Chat tool loop reached its safety limit");
    if (std.mem.trim(u8, assistant, " \t\r\n").len == 0) return writeChatError(writer, "Provider completed without an assistant response");
    if (chat_output.content.items.len == 0 and assistant.len > 0) try chat_output.writeDelta("text_delta", assistant);
    try history.append(allocator, .{ .role = .assistant, .content = try allocator.dupe(u8, assistant) });
    keep_user = true;
    errdefer {
        var removed = history.pop().?;
        removed.deinit(allocator);
    }
    try saveChatHistory(allocator, io, history_path, history.items);
    try writer.writeAll("{\"type\":\"agent_settled\"}\n");
    try writer.flush();
}

fn admitChat(_: *anyopaque) !void {}

fn writeChatError(writer: *std.Io.Writer, message: []const u8) !void {
    try writer.writeAll("{\"type\":\"extension_error\",\"message\":");
    try std.json.Stringify.value(message, .{}, writer);
    try writer.writeAll("}\n{\"type\":\"agent_settled\"}\n");
    try writer.flush();
}

fn loadChatToolCatalog(allocator: std.mem.Allocator, io: std.Io, bridge: BridgeConfig, browser_enabled: bool) !ChatToolCatalog {
    const client = if (gateway_client) |*value| value else return error.FxGatewayUnavailable;
    const response = try mcp_bridge.handle(allocator, io, client, bridge.base_url, bridge.api_key, bridge.model_id, bridge.session_id, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{}}");
    defer allocator.free(response);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch return error.InvalidMcpResponse;
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.InvalidMcpResponse;
    const result = parsed.value.object.get("result") orelse return error.InvalidMcpResponse;
    if (result != .object) return error.InvalidMcpResponse;
    const values = result.object.get("tools") orelse return error.InvalidMcpResponse;
    if (values != .array) return error.InvalidMcpResponse;
    var count: usize = 0;
    for (values.array.items) |value| {
        if (value != .object) continue;
        const name = jsonString(value.object, "name") orelse continue;
        if (!chatToolAllowed(name, browser_enabled)) continue;
        const schema = value.object.get("inputSchema") orelse std.json.Value{ .object = .empty };
        if (schema != .object) continue;
        if (count == max_chat_tools) break;
        count += 1;
    }
    const tools = try allocator.alloc(stream_provider.DynamicFunctionTool, count);
    errdefer allocator.free(tools);
    var index: usize = 0;
    for (values.array.items) |value| {
        if (value != .object) continue;
        const name = jsonString(value.object, "name") orelse continue;
        if (!chatToolAllowed(name, browser_enabled)) continue;
        if (index == tools.len) break;
        const schema = value.object.get("inputSchema") orelse std.json.Value{ .object = .empty };
        if (schema != .object) continue;
        tools[index] = .{
            .name = name,
            .description = jsonString(value.object, "description") orelse "",
            .input_schema = schema,
        };
        index += 1;
    }
    return .{ .allocator = allocator, .parsed = parsed, .tools = tools };
}

fn chatToolAllowed(name: []const u8, browser_enabled: bool) bool {
    if (std.mem.startsWith(u8, name, "browser_")) return browser_enabled;
    for ([_][]const u8{ "computer__", "mcp-filesystem__", "mcp-git__", "filesystem__", "file__", "git__", "shell__", "terminal__", "ssh__" }) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) return false;
    }
    return true;
}

fn duplicateToolCalls(allocator: std.mem.Allocator, calls: []const types.ToolCall) ![]types.ToolCall {
    const duplicated = try allocator.alloc(types.ToolCall, calls.len);
    for (calls, 0..) |call, index| duplicated[index] = .{
        .id = try allocator.dupe(u8, call.id),
        .name = try allocator.dupe(u8, call.name),
        .arguments_json = try allocator.dupe(u8, call.arguments_json),
        .argument_integrity = call.argument_integrity,
        .provisional_id = if (call.provisional_id) |value| try allocator.dupe(u8, value) else null,
        .provider_result = if (call.provider_result) |value| try allocator.dupe(u8, value) else null,
        .final_identity = call.final_identity,
        .provenance = call.provenance,
    };
    return duplicated;
}

fn callChatTool(allocator: std.mem.Allocator, io: std.Io, bridge: BridgeConfig, catalog: *const ChatToolCatalog, call: types.ToolCall) !ChatToolResult {
    if (!catalog.contains(call.name)) return chatToolFailure(allocator, "Tool is not available to built-in Chat");
    if (call.argument_integrity != .valid) return chatToolFailure(allocator, "Tool arguments were not valid JSON");
    var arguments = std.json.parseFromSlice(std.json.Value, allocator, call.arguments_json, .{}) catch return chatToolFailure(allocator, "Tool arguments were not valid JSON");
    defer arguments.deinit();
    if (arguments.value != .object) return chatToolFailure(allocator, "Tool arguments must be an object");
    var request: std.Io.Writer.Allocating = .init(allocator);
    defer request.deinit();
    try request.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":");
    try std.json.Stringify.value(call.name, .{}, &request.writer);
    try request.writer.writeAll(",\"arguments\":");
    try std.json.Stringify.value(arguments.value, .{}, &request.writer);
    try request.writer.writeAll("}}");
    const client = if (gateway_client) |*value| value else return error.FxGatewayUnavailable;
    const response = mcp_bridge.handle(allocator, io, client, bridge.base_url, bridge.api_key, bridge.model_id, bridge.session_id, request.writer.buffered()) catch |failure| return chatToolFailure(allocator, @errorName(failure));
    defer allocator.free(response);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch return chatToolFailure(allocator, "Tool returned an invalid response");
    defer parsed.deinit();
    if (parsed.value != .object) return chatToolFailure(allocator, "Tool returned an invalid response");
    if (parsed.value.object.get("error")) |tool_error| return .{ .text = try boundedJson(allocator, tool_error), .is_error = true };
    const result = parsed.value.object.get("result") orelse return chatToolFailure(allocator, "Tool returned no result");
    const is_error = result == .object and (jsonBool(result.object, "isError") orelse false);
    return .{ .text = try boundedJson(allocator, result), .is_error = is_error };
}

fn chatToolFailure(allocator: std.mem.Allocator, message: []const u8) !ChatToolResult {
    return .{ .text = try allocator.dupe(u8, message), .is_error = true };
}

fn boundedJson(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try std.json.Stringify.value(value, .{}, &output.writer);
    const document = output.writer.buffered();
    if (document.len <= max_chat_tool_result_bytes) return output.toOwnedSlice();
    const marker = "\n[tool result truncated by Local Studio]";
    const result = try allocator.alloc(u8, max_chat_tool_result_bytes + marker.len);
    @memcpy(result[0..max_chat_tool_result_bytes], document[0..max_chat_tool_result_bytes]);
    @memcpy(result[max_chat_tool_result_bytes..], marker);
    return result;
}

fn loadChatHistory(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !std.ArrayList(ChatHistoryEntry) {
    var history: std.ArrayList(ChatHistoryEntry) = .empty;
    errdefer {
        for (history.items) |*entry| entry.deinit(allocator);
        history.deinit(allocator);
    }
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return history;
    defer file.close(io);
    const length: usize = @intCast(try file.length(io));
    if (length == 0 or length > max_sse_aggregate_bytes) return history;
    const storage = try allocator.alloc(u8, length);
    defer allocator.free(storage);
    const read = try file.readPositionalAll(io, storage, 0);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, storage[0..read], .{}) catch return history;
    defer parsed.deinit();
    if (parsed.value != .array) return history;
    for (parsed.value.array.items) |value| {
        if (value != .object) continue;
        const role_text = jsonString(value.object, "role") orelse continue;
        const content = jsonString(value.object, "content") orelse continue;
        const role: types.ChatRole = if (std.mem.eql(u8, role_text, "user")) .user else if (std.mem.eql(u8, role_text, "assistant")) .assistant else continue;
        try history.append(allocator, .{ .role = role, .content = try allocator.dupe(u8, content) });
    }
    return history;
}

fn saveChatHistory(allocator: std.mem.Allocator, io: std.Io, path: []const u8, history: []const ChatHistoryEntry) !void {
    var document: std.Io.Writer.Allocating = .init(allocator);
    defer document.deinit();
    try document.writer.writeByte('[');
    for (history, 0..) |entry, index| {
        if (index > 0) try document.writer.writeByte(',');
        try document.writer.writeAll("{\"role\":");
        try std.json.Stringify.value(@tagName(entry.role), .{}, &document.writer);
        try document.writer.writeAll(",\"content\":");
        try std.json.Stringify.value(entry.content, .{}, &document.writer);
        try document.writer.writeByte('}');
    }
    try document.writer.writeByte(']');
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .permissions = @enumFromInt(0o600), .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, document.writer.buffered());
}

fn jsonString(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

fn jsonBool(object: std.json.ObjectMap, name: []const u8) ?bool {
    const value = object.get(name) orelse return null;
    return if (value == .bool) value.bool else null;
}

fn streamCompletion(_: ?*anyopaque, allocator: std.mem.Allocator, request: stream_provider.ModelRequest) !stream_provider.Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    const endpoint = io_mod.getenv("LOCAL_STUDIO_FX_GATEWAY_URL") orelse return error.FxGatewayRequired;
    const payload = try openai_codex.buildRequest(allocator, request.data());
    defer allocator.free(payload);
    const authorization = try std.fmt.allocPrint(allocator, "Bearer {s}", .{request.credential.secret});
    defer allocator.free(authorization);
    const uri = try std.Uri.parse(endpoint);
    const client = if (gateway_client) |*value| value else return error.FxGatewayUnavailable;
    try request.admission.admit();
    var http_request = try client.request(.POST, uri, .{
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .authorization = .{ .override = authorization },
            .accept_encoding = .omit,
        },
        .extra_headers = &.{.{ .name = "Accept", .value = "text/event-stream" }},
        .keep_alive = true,
        .redirect_behavior = .unhandled,
    });
    defer http_request.deinit();
    request.delivery.markPossiblySent();
    http_request.transfer_encoding = .{ .content_length = payload.len };
    var send_buffer: [8192]u8 = undefined;
    var body_writer = try http_request.sendBodyUnflushed(&send_buffer);
    try body_writer.writer.writeAll(payload);
    try body_writer.end();
    if (http_request.connection) |connection| try connection.flush();
    var response = try http_request.receiveHead(&.{});
    if (response.head.status != .ok) {
        var transfer: [16 * 1024]u8 = undefined;
        const reader = response.reader(&transfer);
        const detail = reader.allocRemaining(allocator, .limited(max_error_body_bytes)) catch |failure| switch (failure) {
            error.StreamTooLong => try allocator.dupe(u8, "Provider error response exceeded the local limit"),
            else => return failure,
        };
        return .{ .failed = .{
            .kind = failureKind(response.head.status),
            .detail = detail,
            .ownership = .owned,
        } };
    }
    var transfer: [256 * 1024]u8 = undefined;
    const reader = response.reader(&transfer);
    var reducer = responses_protocol.Reducer.init(allocator);
    defer reducer.deinit(allocator);
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(allocator);
    var terminal_content: std.ArrayList(u8) = .empty;
    defer terminal_content.deinit(allocator);
    const callbacks = responses_protocol.StreamCallbacks{
        .context = @ptrCast(@constCast(&request.events)),
        .on_content = EventBridge.content,
        .on_tool_start = EventBridge.toolStart,
        .on_reasoning = EventBridge.reasoning,
        .on_tool_input = EventBridge.toolInput,
    };
    const limits = responses_protocol.StreamLimits{
        .aggregate_bytes = max_sse_aggregate_bytes,
        .events = max_sse_events,
        .tool_calls = max_tool_calls,
        .tool_identity_bytes = max_tool_identity_bytes,
        .tool_arguments_bytes = max_tool_arguments_bytes,
        .provider_state_bytes = max_provider_state_bytes,
    };
    while (try nextSseData(allocator, reader, &pending)) |data| {
        defer pending.clearRetainingCapacity();
        try captureTerminalContent(allocator, data, &terminal_content);
        if (try reducer.applyJson(allocator, data, callbacks, request.cancel_flag, request.content_capture_limit, limits)) break;
    }
    var completion = try reducer.finish(allocator, request.cancel_flag, limits);
    if (completion.content == null and terminal_content.items.len > 0) {
        request.events.emit(.{ .content_delta = terminal_content.items });
        completion.content = try terminal_content.toOwnedSlice(allocator);
        terminal_content = .empty;
    }
    return .{ .completed = .{
        .completion = completion,
        .usage = .{ .immediate = null },
        .ownership = .owned,
    } };
}

fn captureTerminalContent(allocator: std.mem.Allocator, document: []const u8, content: *std.ArrayList(u8)) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, document, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const event_type = jsonString(parsed.value.object, "type") orelse return;
    if (!std.mem.eql(u8, event_type, "response.completed") and !std.mem.eql(u8, event_type, "response.done")) return;
    const response = parsed.value.object.get("response") orelse return;
    if (response != .object) return;
    const output = response.object.get("output") orelse return;
    if (output != .array) return;
    for (output.array.items) |item| {
        if (item != .object or !std.mem.eql(u8, jsonString(item.object, "type") orelse "", "message")) continue;
        const parts = item.object.get("content") orelse continue;
        if (parts != .array) continue;
        for (parts.array.items) |part| {
            if (part != .object) continue;
            const text = jsonString(part.object, "text") orelse jsonString(part.object, "refusal") orelse continue;
            try content.appendSlice(allocator, text);
        }
    }
}

fn nextSseData(allocator: std.mem.Allocator, reader: *std.Io.Reader, pending: *std.ArrayList(u8)) !?[]const u8 {
    while (true) {
        const fragment = reader.takeDelimiter('\n') catch |failure| switch (failure) {
            error.StreamTooLong => {
                const buffered = reader.buffered();
                if (buffered.len == 0 or buffered.len > max_sse_line_bytes - pending.items.len) return error.FxSseEventTooLarge;
                try pending.appendSlice(allocator, buffered);
                reader.tossBuffered();
                continue;
            },
            else => return failure,
        } orelse {
            if (pending.items.len == 0) return null;
            return sseData(pending.items);
        };
        if (fragment.len > max_sse_line_bytes - pending.items.len) return error.FxSseEventTooLarge;
        if (pending.items.len > 0) {
            try pending.appendSlice(allocator, fragment);
            return sseData(pending.items);
        }
        if (sseData(fragment)) |data| return data;
    }
}

fn sseData(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (!std.mem.startsWith(u8, trimmed, "data:")) return null;
    const data = std.mem.trim(u8, trimmed[5..], " \t");
    if (std.mem.eql(u8, data, "[DONE]")) return null;
    return data;
}

const EventBridge = struct {
    fn sink(raw: *anyopaque) *const stream_provider.EventSink {
        return @ptrCast(@alignCast(raw));
    }

    fn content(raw: *anyopaque, chunk: []const u8) void {
        sink(raw).emit(.{ .content_delta = chunk });
    }

    fn reasoning(raw: *anyopaque, chunk: []const u8) void {
        sink(raw).emit(.{ .reasoning_delta = chunk });
    }

    fn toolInput(raw: *anyopaque, chunk: []const u8) void {
        sink(raw).emit(.{ .tool_input_delta = chunk });
    }

    fn toolStart(raw: *anyopaque, id: []const u8, name: []const u8, label: ?[]const u8) void {
        sink(raw).emit(.{ .tool_started = .{ .id = id, .name = name, .label = label } });
    }
};

fn failureKind(status: std.http.Status) stream_provider.FailureKind {
    return switch (status) {
        .bad_request => .invalid_request,
        .unauthorized => .unauthorized,
        .forbidden => .forbidden,
        .payload_too_large => .request_too_large,
        .too_many_requests => .rate_limited,
        .internal_server_error => .server_error,
        .bad_gateway => .bad_gateway,
        .service_unavailable => .unavailable,
        .gateway_timeout => .gateway_timeout,
        else => .provider_error,
    };
}

fn firstEnvironment(environment: *const std.process.Environ.Map, names: []const []const u8) ?[]const u8 {
    for (names) |name| if (environment.get(name)) |value| {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len > 0) return trimmed;
    };
    return null;
}
