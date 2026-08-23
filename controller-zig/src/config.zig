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
    mode: Mode,
    host: []const u8,
    port: u16,
    db_path: ?[]const u8,
    spike_upstream: ?[]const u8,
    spike_fallback_upstream: ?[]const u8,

    pub fn load(init: std.process.Init) !Config {
        var config: Config = .{
            .mode = try Mode.parse(init.environ_map.get("LOCAL_STUDIO_CONTROLLER_MODE") orelse "standalone"),
            .host = init.environ_map.get("LOCAL_STUDIO_HOST") orelse "127.0.0.1",
            .port = try parsePort(init.environ_map.get("LOCAL_STUDIO_PORT") orelse "8080"),
            .db_path = init.environ_map.get("LOCAL_STUDIO_DB_PATH"),
            .spike_upstream = init.environ_map.get("LOCAL_STUDIO_ZIG_SPIKE_UPSTREAM"),
            .spike_fallback_upstream = init.environ_map.get("LOCAL_STUDIO_ZIG_SPIKE_FALLBACK_UPSTREAM"),
        };

        var arguments = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
        defer arguments.deinit();
        _ = arguments.skip();
        while (arguments.next()) |argument| {
            if (std.mem.eql(u8, argument, "--mode")) {
                config.mode = try Mode.parse(arguments.next() orelse return error.MissingArgumentValue);
            } else if (std.mem.eql(u8, argument, "--host")) {
                config.host = arguments.next() orelse return error.MissingArgumentValue;
            } else if (std.mem.eql(u8, argument, "--port")) {
                config.port = try parsePort(arguments.next() orelse return error.MissingArgumentValue);
            } else {
                return error.UnknownArgument;
            }
        }
        return config;
    }
};

fn parsePort(value: []const u8) !u16 {
    const port = try std.fmt.parseInt(u16, value, 10);
    if (port == 0) return error.InvalidPort;
    return port;
}
