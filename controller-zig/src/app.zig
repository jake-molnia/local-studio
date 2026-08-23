const std = @import("std");
const config_module = @import("config.zig");
const http_server = @import("http_server.zig");
const system_info = @import("platform/system_info.zig");
const rig_node_credentials = @import("repository/rig_node_credentials.zig");
const rigs = @import("repository/rigs.zig");
const shutdown_module = @import("shutdown.zig");
const sqlite = @import("repository/sqlite.zig");

const Io = std.Io;

pub const App = struct {
    io: Io,
    config: config_module.Config,
    database: sqlite.Database,
    system: system_info.Snapshot,
    shutdown: shutdown_module.Shutdown,
    server: http_server.HttpServer,

    pub fn init(allocator: std.mem.Allocator, io: Io, config: config_module.Config) !App {
        _ = try std.Io.Dir.cwd().createDirPathStatus(io, config.data_dir, @enumFromInt(0o700));
        var database = try sqlite.Database.open(allocator, config.db_path);
        errdefer database.deinit();
        if (!try database.quickCheck()) return error.DatabaseIntegrityCheckFailed;
        try rigs.initialize(&database);
        try rig_node_credentials.initialize(&database);
        std.log.info("SQLite {s} compatibility database opened", .{database.version()});

        var system = try system_info.detect(allocator);
        errdefer system.deinit();

        var shutdown = try shutdown_module.Shutdown.init();
        errdefer shutdown.deinit();
        const server = try http_server.HttpServer.init(allocator, io, config);
        return .{
            .io = io,
            .config = config,
            .database = database,
            .system = system,
            .shutdown = shutdown,
            .server = server,
        };
    }

    pub fn deinit(app: *App) void {
        app.server.deinit();
        app.shutdown.deinit();
        app.system.deinit();
        app.database.deinit();
        app.config.deinit();
        app.* = undefined;
    }

    pub fn run(app: *App) !void {
        var server_task = try app.io.concurrent(runServer, .{ &app.server, &app.database, &app.system, &app.shutdown });
        defer server_task.cancel(app.io) catch |failure| switch (failure) {
            error.Canceled => {},
        };
        std.log.info("controller mode={t} node={s} listening on {s}:{d}", .{ app.config.mode, app.system.hostname, app.config.host, app.config.port });
        try app.shutdown.wait();
        std.log.info("controller shutdown complete", .{});
    }
};

fn runServer(server: *http_server.HttpServer, database: *sqlite.Database, system: *const system_info.Snapshot, shutdown: *shutdown_module.Shutdown) Io.Cancelable!void {
    server.run(database, system) catch |failure| switch (failure) {
        error.Canceled => return error.Canceled,
        else => std.log.err("controller server stopped: {t}", .{failure}),
    };
    shutdown.request();
}
