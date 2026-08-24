const std = @import("std");

const Io = std.Io;
const max_document_bytes = 8 * 1024 * 1024;
const modern_protocol = "2026-07-28";

pub fn run(init: std.process.Init) !void {
    const base_url = requiredEnvironment(init.environ_map, "LOCAL_STUDIO_MCP_BRIDGE_URL") orelse return error.BridgeUrlRequired;
    const model_id = requiredEnvironment(init.environ_map, "LOCAL_STUDIO_MCP_BRIDGE_MODEL") orelse return error.BridgeModelRequired;
    const api_key = requiredEnvironment(init.environ_map, "LOCAL_STUDIO_MCP_BRIDGE_KEY");
    var client: std.http.Client = .{ .allocator = init.gpa, .io = init.io };
    defer client.deinit();
    var input_buffer: [16 * 1024]u8 = undefined;
    var output_buffer: [16 * 1024]u8 = undefined;
    var input = Io.File.stdin().reader(init.io, &input_buffer);
    var output = Io.File.stdout().writer(init.io, &output_buffer);
    while (try input.interface.takeDelimiter('\n')) |line_value| {
        const line = std.mem.trim(u8, line_value, " \t\r");
        if (line.len == 0) continue;
        if (line.len > max_document_bytes) return error.McpRequestTooLarge;
        const response = handle(init.gpa, init.io, &client, base_url, api_key, model_id, line) catch |failure| try errorResponse(init.gpa, line, failure);
        defer init.gpa.free(response);
        if (response.len == 0) continue;
        try output.interface.writeAll(response);
        try output.interface.writeByte('\n');
        try output.interface.flush();
    }
}

fn handle(allocator: std.mem.Allocator, io: Io, client: *std.http.Client, base_url: []const u8, api_key: ?[]const u8, model_id: []const u8, document: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, document, .{}) catch return error.InvalidMcpRequest;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidMcpRequest;
    const object = parsed.value.object;
    const method = stringField(object, "method") orelse return error.McpMethodRequired;
    const id = object.get("id");
    if (std.mem.eql(u8, method, "notifications/initialized")) return allocator.dupe(u8, "");
    if (id == null) return allocator.dupe(u8, "");
    if (std.mem.eql(u8, method, "server/discover")) return discoverResponse(allocator, id.?);
    if (std.mem.eql(u8, method, "initialize")) return initializeResponse(allocator, id.?, object.get("params"));
    if (std.mem.eql(u8, method, "tools/list")) return toolsResponse(allocator, io, client, base_url, api_key, model_id, id.?);
    if (std.mem.eql(u8, method, "tools/call")) return callResponse(allocator, io, client, base_url, api_key, model_id, id.?, object.get("params"));
    return rpcError(allocator, id.?, -32601, "unknown method");
}

fn discoverResponse(allocator: std.mem.Allocator, id: std.json.Value) ![]u8 {
    var output: Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try std.json.Stringify.value(id, .{}, &output.writer);
    try output.writer.writeAll(",\"result\":{\"supportedVersions\":[\"2026-07-28\"],\"capabilities\":{\"tools\":{\"listChanged\":true}},\"resultType\":\"complete\",\"ttlMs\":0,\"cacheScope\":\"private\",\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"local-studio\",\"version\":\"2.1.0\"}}}}");
    return output.toOwnedSlice();
}

fn initializeResponse(allocator: std.mem.Allocator, id: std.json.Value, params: ?std.json.Value) ![]u8 {
    const protocol = if (params) |value| if (value == .object) stringField(value.object, "protocolVersion") orelse "2025-06-18" else "2025-06-18" else "2025-06-18";
    var output: Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try std.json.Stringify.value(id, .{}, &output.writer);
    try output.writer.writeAll(",\"result\":{\"protocolVersion\":");
    try std.json.Stringify.value(protocol, .{}, &output.writer);
    try output.writer.writeAll(",\"capabilities\":{\"tools\":{\"listChanged\":true}},\"serverInfo\":{\"name\":\"local-studio\",\"version\":\"2.1.0\"}}}");
    return output.toOwnedSlice();
}

fn toolsResponse(allocator: std.mem.Allocator, io: Io, client: *std.http.Client, base_url: []const u8, api_key: ?[]const u8, model_id: []const u8, id: std.json.Value) ![]u8 {
    const encoded_model = try encodeQuery(allocator, model_id);
    defer allocator.free(encoded_model);
    const url = try std.fmt.allocPrint(allocator, "{s}/internal/node/v1/connector-call?model_id={s}", .{ base_url, encoded_model });
    defer allocator.free(url);
    const inventory = try request(allocator, io, client, url, api_key, .GET, null);
    defer allocator.free(inventory);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, inventory, .{}) catch return error.InvalidConnectorInventory;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidConnectorInventory;
    const connectors = parsed.value.object.get("connectors") orelse return error.InvalidConnectorInventory;
    if (connectors != .array) return error.InvalidConnectorInventory;
    var output: Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try std.json.Stringify.value(id, .{}, &output.writer);
    try output.writer.writeAll(",\"result\":{\"tools\":[");
    var wrote = false;
    for (connectors.array.items) |connector| {
        if (connector != .object) continue;
        const connector_id = stringField(connector.object, "id") orelse continue;
        const tools = connector.object.get("tools") orelse continue;
        if (tools != .array) continue;
        for (tools.array.items) |tool| {
            if (tool != .object) continue;
            const name = stringField(tool.object, "name") orelse continue;
            if (wrote) try output.writer.writeByte(',');
            try output.writer.writeAll("{\"name\":");
            const namespaced = try std.fmt.allocPrint(allocator, "{s}__{s}", .{ connector_id, name });
            defer allocator.free(namespaced);
            try std.json.Stringify.value(namespaced, .{}, &output.writer);
            if (tool.object.get("description")) |description| {
                try output.writer.writeAll(",\"description\":");
                try std.json.Stringify.value(description, .{}, &output.writer);
            }
            try output.writer.writeAll(",\"inputSchema\":");
            if (tool.object.get("inputSchema")) |schema| try std.json.Stringify.value(schema, .{}, &output.writer) else try output.writer.writeAll("{\"type\":\"object\"}");
            try output.writer.writeByte('}');
            wrote = true;
        }
    }
    try output.writer.writeAll("]}}");
    return output.toOwnedSlice();
}

fn callResponse(allocator: std.mem.Allocator, io: Io, client: *std.http.Client, base_url: []const u8, api_key: ?[]const u8, model_id: []const u8, id: std.json.Value, params_value: ?std.json.Value) ![]u8 {
    const params = params_value orelse return error.McpParamsRequired;
    if (params != .object) return error.McpParamsRequired;
    const namespaced = stringField(params.object, "name") orelse return error.McpToolRequired;
    const separator = std.mem.indexOf(u8, namespaced, "__") orelse return error.InvalidMcpToolName;
    if (separator == 0 or separator + 2 >= namespaced.len) return error.InvalidMcpToolName;
    const connector_id = namespaced[0..separator];
    const tool_name = namespaced[separator + 2 ..];
    const arguments: std.json.Value = params.object.get("arguments") orelse .{ .object = .empty };
    if (arguments != .object) return error.InvalidMcpArguments;
    var body: Io.Writer.Allocating = .init(allocator);
    defer body.deinit();
    try body.writer.writeAll("{\"connector_id\":");
    try std.json.Stringify.value(connector_id, .{}, &body.writer);
    try body.writer.writeAll(",\"tool\":");
    try std.json.Stringify.value(tool_name, .{}, &body.writer);
    try body.writer.writeAll(",\"model_id\":");
    try std.json.Stringify.value(model_id, .{}, &body.writer);
    try body.writer.writeAll(",\"args\":");
    try std.json.Stringify.value(arguments, .{}, &body.writer);
    try body.writer.writeByte('}');
    const url = try std.fmt.allocPrint(allocator, "{s}/internal/node/v1/connector-call", .{base_url});
    defer allocator.free(url);
    const called = try request(allocator, io, client, url, api_key, .POST, body.writer.buffered());
    defer allocator.free(called);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, called, .{}) catch return error.InvalidConnectorResponse;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidConnectorResponse;
    const result = parsed.value.object.get("result") orelse return error.InvalidConnectorResponse;
    var output: Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try std.json.Stringify.value(id, .{}, &output.writer);
    try output.writer.writeAll(",\"result\":");
    try std.json.Stringify.value(result, .{}, &output.writer);
    try output.writer.writeByte('}');
    return output.toOwnedSlice();
}

fn request(allocator: std.mem.Allocator, _: Io, client: *std.http.Client, url: []const u8, api_key: ?[]const u8, method: std.http.Method, body: ?[]const u8) ![]u8 {
    const uri = std.Uri.parse(url) catch return error.InvalidBridgeUrl;
    var authorization: ?[]u8 = null;
    defer if (authorization) |value| allocator.free(value);
    var headers: [2]std.http.Header = undefined;
    var header_count: usize = 0;
    if (api_key) |key| {
        authorization = try std.fmt.allocPrint(allocator, "Bearer {s}", .{key});
        headers[header_count] = .{ .name = "Authorization", .value = authorization.? };
        header_count += 1;
    }
    if (body != null) {
        headers[header_count] = .{ .name = "Content-Type", .value = "application/json" };
        header_count += 1;
    }
    var http_request = try client.request(method, uri, .{
        .redirect_behavior = .unhandled,
        .keep_alive = false,
        .headers = .{ .authorization = .omit, .user_agent = .omit, .connection = .omit, .accept_encoding = .omit, .content_type = .omit },
        .extra_headers = headers[0..header_count],
    });
    defer http_request.deinit();
    if (body) |document| {
        http_request.transfer_encoding = .{ .content_length = document.len };
        var write_buffer: [16 * 1024]u8 = undefined;
        var request_body = try http_request.sendBody(&write_buffer);
        try request_body.writer.writeAll(document);
        try request_body.end();
    } else try http_request.sendBodiless();
    var redirect_buffer: [16 * 1024]u8 = undefined;
    var response = try http_request.receiveHead(&redirect_buffer);
    if (@intFromEnum(response.head.status) < 200 or @intFromEnum(response.head.status) >= 300) return error.BridgeRequestRejected;
    const storage = try allocator.alloc(u8, max_document_bytes);
    defer allocator.free(storage);
    var output: Io.Writer = .fixed(storage);
    var read_buffer: [16 * 1024]u8 = undefined;
    _ = response.reader(&read_buffer).streamRemaining(&output) catch return error.BridgeResponseTooLarge;
    return allocator.dupe(u8, output.buffered());
}

fn encodeQuery(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var output: Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    for (value) |character| {
        if (std.ascii.isAlphanumeric(character) or character == '-' or character == '_' or character == '.' or character == '~') try output.writer.writeByte(character) else try output.writer.print("%{X:0>2}", .{character});
    }
    return output.toOwnedSlice();
}

fn errorResponse(allocator: std.mem.Allocator, request_document: []const u8, failure: anyerror) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, request_document, .{}) catch return rpcError(allocator, .null, -32700, "parse error");
    defer parsed.deinit();
    const id = if (parsed.value == .object) parsed.value.object.get("id") orelse .null else .null;
    return rpcError(allocator, id, -32603, @errorName(failure));
}

fn rpcError(allocator: std.mem.Allocator, id: std.json.Value, code: i32, message: []const u8) ![]u8 {
    var output: Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try std.json.Stringify.value(id, .{}, &output.writer);
    try output.writer.print(",\"error\":{{\"code\":{d},\"message\":", .{code});
    try std.json.Stringify.value(message, .{}, &output.writer);
    try output.writer.writeAll("}}");
    return output.toOwnedSlice();
}

fn requiredEnvironment(environment: *const std.process.Environ.Map, name: []const u8) ?[]const u8 {
    const value = environment.get(name) orelse return null;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    return if (trimmed.len == 0) null else trimmed;
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}
