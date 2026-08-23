const std = @import("std");

pub const Mode = enum {
    head,
    worker,
    standalone,

    pub fn parse(value: []const u8) !Mode {
        return std.meta.stringToEnum(Mode, value) orelse error.InvalidControllerMode;
    }
};

pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    mode: Mode,
    host: []const u8,
    port: u16,
    inference_host: []const u8,
    inference_port: u16,
    data_dir: []const u8,
    db_path: []const u8,
    llm_instance_path: []const u8,
    models_dir: []const u8,
    api_key: ?[]const u8,
    spike_upstream: ?[]const u8,
    spike_fallback_upstream: ?[]const u8,

    pub fn load(init: std.process.Init) !Config {
        var arena = std.heap.ArenaAllocator.init(init.gpa);
        errdefer arena.deinit();
        const allocator = arena.allocator();

        var mode_value = init.environ_map.get("LOCAL_STUDIO_CONTROLLER_MODE") orelse "standalone";
        var host_value = init.environ_map.get("LOCAL_STUDIO_HOST") orelse "127.0.0.1";
        var port_value = init.environ_map.get("LOCAL_STUDIO_PORT") orelse "8080";
        var arguments = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
        defer arguments.deinit();
        _ = arguments.skip();
        while (arguments.next()) |argument| {
            if (std.mem.eql(u8, argument, "--mode")) {
                mode_value = arguments.next() orelse return error.MissingArgumentValue;
            } else if (std.mem.eql(u8, argument, "--host")) {
                host_value = arguments.next() orelse return error.MissingArgumentValue;
            } else if (std.mem.eql(u8, argument, "--port")) {
                port_value = arguments.next() orelse return error.MissingArgumentValue;
            } else {
                return error.UnknownArgument;
            }
        }

        const cwd = try std.Io.Dir.cwd().realPathFileAlloc(init.io, ".", allocator);
        const data_dir = if (init.environ_map.get("LOCAL_STUDIO_DATA_DIR")) |configured|
            try absolutePath(allocator, cwd, configured)
        else
            try std.fs.path.join(allocator, &.{ cwd, "data" });
        const db_path = if (init.environ_map.get("LOCAL_STUDIO_DB_PATH")) |configured|
            if (std.mem.eql(u8, configured, ":memory:")) configured else try absolutePath(allocator, cwd, configured)
        else
            try std.fs.path.join(allocator, &.{ data_dir, "controller.db" });
        const llm_instance_path = try std.fs.path.join(allocator, &.{ data_dir, "instances", "llm.json" });
        const models_value = init.environ_map.get("LOCAL_STUDIO_MODELS_DIR") orelse "/models";
        const host = try allocator.dupe(u8, std.mem.trim(u8, host_value, " \t\r\n"));
        const inference_host = try allocator.dupe(u8, init.environ_map.get("LOCAL_STUDIO_INFERENCE_HOST") orelse "localhost");
        const models_dir = try absolutePath(allocator, cwd, models_value);
        const api_key = try optionalOwned(allocator, init.environ_map.get("LOCAL_STUDIO_API_KEY"));
        const spike_upstream = try optionalOwned(allocator, init.environ_map.get("LOCAL_STUDIO_ZIG_SPIKE_UPSTREAM"));
        const spike_fallback_upstream = try optionalOwned(allocator, init.environ_map.get("LOCAL_STUDIO_ZIG_SPIKE_FALLBACK_UPSTREAM"));

        return .{
            .arena = arena,
            .mode = try Mode.parse(mode_value),
            .host = host,
            .port = try parsePort(port_value),
            .inference_host = inference_host,
            .inference_port = try parsePort(init.environ_map.get("LOCAL_STUDIO_INFERENCE_PORT") orelse "8000"),
            .data_dir = data_dir,
            .db_path = db_path,
            .llm_instance_path = llm_instance_path,
            .models_dir = models_dir,
            .api_key = api_key,
            .spike_upstream = spike_upstream,
            .spike_fallback_upstream = spike_fallback_upstream,
        };
    }

    pub fn deinit(config: *Config) void {
        config.arena.deinit();
        config.* = undefined;
    }
};

fn absolutePath(allocator: std.mem.Allocator, cwd: []const u8, value: []const u8) ![]const u8 {
    return if (std.fs.path.isAbsolute(value))
        try allocator.dupe(u8, value)
    else
        try std.fs.path.resolve(allocator, &.{ cwd, value });
}

fn optionalOwned(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    const candidate = std.mem.trim(u8, value orelse return null, " \t\r\n");
    return if (candidate.len == 0) null else try allocator.dupe(u8, candidate);
}

fn parsePort(value: []const u8) !u16 {
    const port = try std.fmt.parseInt(u16, value, 10);
    if (port == 0) return error.InvalidPort;
    return port;
}
