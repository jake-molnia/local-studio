const std = @import("std");
const auth = @import("services/code_storage_auth.zig");

const Io = std.Io;
const max_line_bytes = 1024 * 1024;
const max_response_bytes = 8 * 1024 * 1024;
const max_git_output_bytes = 2 * 1024 * 1024;

pub fn run(init: std.process.Init) !void {
    const organization = init.environ_map.get("CODE_STORAGE_ORGANIZATION") orelse return error.CodeStorageOrganizationRequired;
    const private_key = init.environ_map.get("CODE_STORAGE_PRIVATE_KEY") orelse return error.CodeStoragePrivateKeyRequired;
    const account_id = init.environ_map.get("CODE_STORAGE_ACCOUNT_ID") orelse return error.CodeStorageAccountRequired;
    try auth.validateOrganization(organization);
    try auth.validatePrivateKey(init.gpa, private_key);
    var client: std.http.Client = .{ .allocator = init.gpa, .io = init.io };
    defer client.deinit();
    var input_buffer: [16 * 1024]u8 = undefined;
    var output_buffer: [16 * 1024]u8 = undefined;
    var input = Io.File.stdin().reader(init.io, &input_buffer);
    var output = Io.File.stdout().writer(init.io, &output_buffer);
    while (try input.interface.takeDelimiter('\n')) |line_value| {
        const line = std.mem.trim(u8, line_value, " \t\r");
        if (line.len == 0) continue;
        if (line.len > max_line_bytes) return error.McpRequestTooLarge;
        const response = handle(init.gpa, init.io, &client, organization, account_id, private_key, line) catch |failure| try errorResponse(init.gpa, line, failure);
        defer init.gpa.free(response);
        if (response.len == 0) continue;
        try output.interface.writeAll(response);
        try output.interface.writeByte('\n');
        try output.interface.flush();
    }
}

fn handle(allocator: std.mem.Allocator, io: Io, client: *std.http.Client, organization: []const u8, account_id: []const u8, private_key: []const u8, document: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, document, .{}) catch return error.InvalidMcpRequest;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidMcpRequest;
    const object = parsed.value.object;
    const method = stringField(object, "method") orelse return error.McpMethodRequired;
    if (std.mem.eql(u8, method, "notifications/initialized")) return allocator.dupe(u8, "");
    const id = object.get("id") orelse return allocator.dupe(u8, "");
    if (std.mem.eql(u8, method, "initialize")) return initializeResponse(allocator, id, object.get("params"), organization);
    if (std.mem.eql(u8, method, "tools/list")) return toolsResponse(allocator, id);
    if (std.mem.eql(u8, method, "tools/call")) return callResponse(allocator, io, client, id, object.get("params"), organization, account_id, private_key);
    return rpcError(allocator, id, -32601, "unknown method");
}

fn initializeResponse(allocator: std.mem.Allocator, id: std.json.Value, params: ?std.json.Value, organization: []const u8) ![]u8 {
    const protocol = if (params) |value| if (value == .object) stringField(value.object, "protocolVersion") orelse "2025-06-18" else "2025-06-18" else "2025-06-18";
    var output: Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try std.json.Stringify.value(id, .{}, &output.writer);
    try output.writer.writeAll(",\"result\":{\"protocolVersion\":");
    try std.json.Stringify.value(protocol, .{}, &output.writer);
    try output.writer.writeAll(",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":");
    const name = try std.fmt.allocPrint(allocator, "code-storage({s})", .{organization});
    defer allocator.free(name);
    try std.json.Stringify.value(name, .{}, &output.writer);
    try output.writer.writeAll(",\"version\":\"1.0.0\"}}}");
    return output.toOwnedSlice();
}

fn toolsResponse(allocator: std.mem.Allocator, id: std.json.Value) ![]u8 {
    var output: Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try std.json.Stringify.value(id, .{}, &output.writer);
    try output.writer.writeAll(",\"result\":{\"tools\":[");
    try writeTool(&output.writer, "list_repositories", "List repositories available to this Code.Storage organization.", "{\"type\":\"object\",\"properties\":{\"limit\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":100},\"cursor\":{\"type\":\"string\"}}}");
    try output.writer.writeByte(',');
    try writeTool(&output.writer, "clone_repository", "Clone a Code.Storage repository into an absolute local path without exposing its credential.", "{\"type\":\"object\",\"properties\":{\"repository\":{\"type\":\"string\"},\"destination\":{\"type\":\"string\"},\"ref\":{\"type\":\"string\"}},\"required\":[\"repository\",\"destination\"]}");
    try output.writer.writeByte(',');
    try writeTool(&output.writer, "fetch_repository", "Fetch all refs from Code.Storage into an existing local Git repository.", "{\"type\":\"object\",\"properties\":{\"repository\":{\"type\":\"string\"},\"path\":{\"type\":\"string\"}},\"required\":[\"repository\",\"path\"]}");
    try output.writer.writeByte(',');
    try writeTool(&output.writer, "push_repository", "Push a committed local HEAD to a Code.Storage branch without exposing its credential.", "{\"type\":\"object\",\"properties\":{\"repository\":{\"type\":\"string\"},\"path\":{\"type\":\"string\"},\"branch\":{\"type\":\"string\"}},\"required\":[\"repository\",\"path\",\"branch\"]}");
    try output.writer.writeAll("]}}");
    return output.toOwnedSlice();
}

fn writeTool(writer: *Io.Writer, name: []const u8, description: []const u8, schema: []const u8) !void {
    try writer.writeAll("{\"name\":");
    try std.json.Stringify.value(name, .{}, writer);
    try writer.writeAll(",\"description\":");
    try std.json.Stringify.value(description, .{}, writer);
    try writer.writeAll(",\"inputSchema\":");
    try writer.writeAll(schema);
    try writer.writeByte('}');
}

fn callResponse(allocator: std.mem.Allocator, io: Io, client: *std.http.Client, id: std.json.Value, params_value: ?std.json.Value, organization: []const u8, account_id: []const u8, private_key: []const u8) ![]u8 {
    const params = params_value orelse return error.McpParamsRequired;
    if (params != .object) return error.McpParamsRequired;
    const name = stringField(params.object, "name") orelse return error.McpToolRequired;
    const arguments_value = params.object.get("arguments") orelse std.json.Value{ .object = .empty };
    if (arguments_value != .object) return error.InvalidMcpArguments;
    const result = if (std.mem.eql(u8, name, "list_repositories"))
        try listRepositories(allocator, io, client, organization, account_id, private_key, arguments_value.object)
    else if (std.mem.eql(u8, name, "clone_repository") or std.mem.eql(u8, name, "fetch_repository") or std.mem.eql(u8, name, "push_repository"))
        try runGit(allocator, io, name, organization, account_id, private_key, arguments_value.object)
    else
        return error.UnknownMcpTool;
    defer allocator.free(result);
    return toolResult(allocator, id, result, false);
}

fn listRepositories(allocator: std.mem.Allocator, io: Io, client: *std.http.Client, organization: []const u8, account_id: []const u8, private_key: []const u8, arguments: std.json.ObjectMap) ![]u8 {
    const token = try auth.mint(allocator, io, organization, account_id, private_key, null, &.{"org:read"});
    defer allocator.free(token);
    const limit = if (arguments.get("limit")) |value| if (value == .integer) std.math.clamp(value.integer, 1, 100) else 50 else 50;
    var url: Io.Writer.Allocating = .init(allocator);
    defer url.deinit();
    try url.writer.print("https://api.{s}.code.storage/api/v1/repos?limit={d}", .{ organization, limit });
    if (stringField(arguments, "cursor")) |cursor| {
        try url.writer.writeAll("&cursor=");
        try writeQuery(&url.writer, cursor);
    }
    const uri = try std.Uri.parse(url.writer.buffered());
    const authorization = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
    defer allocator.free(authorization);
    var request = try client.request(.GET, uri, .{
        .redirect_behavior = .unhandled,
        .keep_alive = false,
        .headers = .{ .authorization = .omit, .accept_encoding = .omit },
        .extra_headers = &.{.{ .name = "Authorization", .value = authorization }},
    });
    defer request.deinit();
    try request.sendBodiless();
    var response = try request.receiveHead(&.{});
    const storage = try allocator.alloc(u8, max_response_bytes);
    defer allocator.free(storage);
    var body: Io.Writer = .fixed(storage);
    var read_buffer: [32 * 1024]u8 = undefined;
    _ = response.reader(&read_buffer).streamRemaining(&body) catch return error.CodeStorageResponseTooLarge;
    if (response.head.status.class() != .success) return error.CodeStorageRequestRejected;
    return allocator.dupe(u8, body.buffered());
}

fn runGit(allocator: std.mem.Allocator, io: Io, operation: []const u8, organization: []const u8, account_id: []const u8, private_key: []const u8, arguments: std.json.ObjectMap) ![]u8 {
    const repository = stringField(arguments, "repository") orelse return error.CodeStorageRepositoryRequired;
    try auth.validateRepository(repository);
    const token = try auth.mint(allocator, io, organization, account_id, private_key, repository, &.{ "git:read", "git:write" });
    defer allocator.free(token);
    const remote = try std.fmt.allocPrint(allocator, "https://t:{s}@{s}.code.storage/{s}.git", .{ token, organization, repository });
    defer allocator.free(remote);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    if (std.mem.eql(u8, operation, "clone_repository")) {
        const destination = stringField(arguments, "destination") orelse return error.CodeStorageDestinationRequired;
        if (!std.fs.path.isAbsolute(destination)) return error.CodeStoragePathMustBeAbsolute;
        try argv.append(allocator, "clone");
        if (stringField(arguments, "ref")) |ref| {
            try validateRef(ref);
            try argv.appendSlice(allocator, &.{ "--branch", ref });
        }
        try argv.appendSlice(allocator, &.{ remote, destination });
    } else {
        const path = stringField(arguments, "path") orelse return error.CodeStoragePathRequired;
        if (!std.fs.path.isAbsolute(path)) return error.CodeStoragePathMustBeAbsolute;
        try argv.appendSlice(allocator, &.{ "-C", path });
        if (std.mem.eql(u8, operation, "fetch_repository")) {
            try argv.appendSlice(allocator, &.{ "fetch", remote, "+refs/heads/*:refs/remotes/code-storage/*" });
        } else {
            const branch = stringField(arguments, "branch") orelse return error.CodeStorageBranchRequired;
            try validateRef(branch);
            const refspec = try std.fmt.allocPrint(allocator, "HEAD:refs/heads/{s}", .{branch});
            defer allocator.free(refspec);
            try argv.appendSlice(allocator, &.{ "push", remote, refspec });
        }
    }
    const result = try std.process.run(allocator, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(max_git_output_bytes),
        .stderr_limit = .limited(max_git_output_bytes),
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(600) } },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    var combined: Io.Writer.Allocating = .init(allocator);
    defer combined.deinit();
    if (result.stdout.len > 0) try combined.writer.writeAll(result.stdout);
    if (result.stderr.len > 0) try combined.writer.writeAll(result.stderr);
    if (combined.writer.buffered().len == 0) try combined.writer.writeAll(if (ok) "Git operation completed." else "Git operation failed.");
    const redacted = try std.mem.replaceOwned(u8, allocator, combined.writer.buffered(), token, "[credential redacted]");
    if (!ok) {
        allocator.free(redacted);
        return error.CodeStorageGitFailed;
    }
    return redacted;
}

fn toolResult(allocator: std.mem.Allocator, id: std.json.Value, text: []const u8, is_error: bool) ![]u8 {
    var output: Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try std.json.Stringify.value(id, .{}, &output.writer);
    try output.writer.writeAll(",\"result\":{\"content\":[{\"type\":\"text\",\"text\":");
    try std.json.Stringify.value(text, .{}, &output.writer);
    try output.writer.print("}}],\"isError\":{}}}}}", .{is_error});
    return output.toOwnedSlice();
}

fn errorResponse(allocator: std.mem.Allocator, request: []const u8, failure: anyerror) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, request, .{}) catch return rpcError(allocator, .null, -32700, "parse error");
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

fn validateRef(value: []const u8) !void {
    if (value.len == 0 or value.len > 255 or value[0] == '-' or value[value.len - 1] == '/' or std.mem.containsAtLeast(u8, value, 1, "..")) return error.InvalidGitRef;
    for (value) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.' and byte != '/') return error.InvalidGitRef;
}

fn writeQuery(writer: *Io.Writer, value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |byte| if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') try writer.writeByte(byte) else {
        try writer.writeByte('%');
        try writer.writeByte(hex[byte >> 4]);
        try writer.writeByte(hex[byte & 15]);
    };
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    if (value != .string) return null;
    const trimmed = std.mem.trim(u8, value.string, " \t\r\n");
    return if (trimmed.len == 0 or trimmed.len > 512 * 1024) null else trimmed;
}
