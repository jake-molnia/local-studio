const std = @import("std");
const config_module = @import("../config.zig");

const Io = std.Io;

pub const Config = struct {
    allocator: std.mem.Allocator,
    io: Io,
    mode: config_module.Mode,
    environment: *const std.process.Environ.Map,
    agent_dir: []u8,
    head_base_url: ?[]u8,
    head_api_key: ?[]u8,

    pub fn init(allocator: std.mem.Allocator, io: Io, configuration: *const config_module.Config) !Config {
        const agent_dir = try std.fs.path.join(allocator, &.{ configuration.data_dir, "harness", "pi", "config" });
        errdefer allocator.free(agent_dir);
        const configured_url = configuration.environment.get("LOCAL_STUDIO_HEAD_URL");
        const base_url = if (configuration.mode == .standalone)
            try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/v1", .{configuration.port})
        else if (configured_url) |value|
            try normalizeBaseUrl(allocator, value)
        else
            null;
        errdefer if (base_url) |value| allocator.free(value);
        const configured_key = configuration.environment.get("LOCAL_STUDIO_HEAD_API_KEY");
        const key = if (configured_key) |value|
            try optionalOwned(allocator, value)
        else if (configuration.mode == .standalone)
            try allocator.dupe(u8, configuration.api_key orelse "local-studio")
        else
            null;
        return .{
            .allocator = allocator,
            .io = io,
            .mode = configuration.mode,
            .environment = configuration.environment,
            .agent_dir = agent_dir,
            .head_base_url = base_url,
            .head_api_key = key,
        };
    }

    pub fn deinit(configuration: *Config) void {
        configuration.allocator.free(configuration.agent_dir);
        if (configuration.head_base_url) |value| configuration.allocator.free(value);
        if (configuration.head_api_key) |value| configuration.allocator.free(value);
        configuration.* = undefined;
    }

    pub fn available(configuration: *const Config) bool {
        return configuration.mode == .standalone or (configuration.head_base_url != null and configuration.head_api_key != null);
    }

    pub fn prepare(configuration: *const Config, model_id: []const u8) !Route {
        const base_url = configuration.head_base_url orelse return error.HeadEndpointRequired;
        const api_key = configuration.head_api_key orelse return error.HeadCredentialRequired;
        if (model_id.len == 0 or model_id.len > 512) return error.InvalidHeadModelId;
        _ = try Io.Dir.cwd().createDirPathStatus(configuration.io, configuration.agent_dir, @enumFromInt(0o700));
        const models_path = try std.fs.path.join(configuration.allocator, &.{ configuration.agent_dir, "models.json" });
        defer configuration.allocator.free(models_path);
        const document = try modelsDocument(configuration.allocator, base_url, model_id);
        defer configuration.allocator.free(document);
        var atomic_file = try Io.Dir.cwd().createFileAtomic(configuration.io, models_path, .{
            .permissions = @enumFromInt(0o600),
            .make_path = true,
            .replace = true,
        });
        defer atomic_file.deinit(configuration.io);
        try atomic_file.file.writeStreamingAll(configuration.io, document);
        try atomic_file.file.sync(configuration.io);
        try atomic_file.replace(configuration.io);
        var environment = try configuration.environment.clone(configuration.allocator);
        errdefer environment.deinit();
        try environment.put("PI_CODING_AGENT_DIR", configuration.agent_dir);
        try environment.put("LOCAL_STUDIO_HEAD_API_KEY", api_key);
        return .{
            .allocator = configuration.allocator,
            .model_name = try std.fmt.allocPrint(configuration.allocator, "local-studio/{s}", .{model_id}),
            .environment = environment,
        };
    }
};

pub const Route = struct {
    allocator: std.mem.Allocator,
    model_name: []u8,
    environment: std.process.Environ.Map,

    pub fn deinit(route: *Route) void {
        route.allocator.free(route.model_name);
        route.environment.deinit();
        route.* = undefined;
    }
};

fn modelsDocument(allocator: std.mem.Allocator, base_url: []const u8, model_id: []const u8) ![]u8 {
    var output: Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"providers\":{\"local-studio\":{\"baseUrl\":");
    try std.json.Stringify.value(base_url, .{}, &output.writer);
    try output.writer.writeAll(",\"api\":\"openai-responses\",\"apiKey\":\"$LOCAL_STUDIO_HEAD_API_KEY\",\"authHeader\":true,\"models\":[{\"id\":");
    try std.json.Stringify.value(model_id, .{}, &output.writer);
    try output.writer.writeAll(",\"name\":");
    try std.json.Stringify.value(model_id, .{}, &output.writer);
    try output.writer.writeAll(",\"reasoning\":true,\"input\":[\"text\",\"image\"]}]}}}");
    return output.toOwnedSlice();
}

fn normalizeBaseUrl(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const trimmed = std.mem.trimEnd(u8, std.mem.trim(u8, value, " \t\r\n"), "/");
    if (trimmed.len == 0) return error.InvalidHeadEndpoint;
    const uri = std.Uri.parse(trimmed) catch return error.InvalidHeadEndpoint;
    if ((!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) or uri.host == null) return error.InvalidHeadEndpoint;
    if (std.mem.endsWith(u8, trimmed, "/v1")) return allocator.dupe(u8, trimmed);
    return std.fmt.allocPrint(allocator, "{s}/v1", .{trimmed});
}

fn optionalOwned(allocator: std.mem.Allocator, value: []const u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    return if (trimmed.len == 0) null else try allocator.dupe(u8, trimmed);
}
