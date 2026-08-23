const std = @import("std");
const config_module = @import("config.zig");
const http_server = @import("http_server.zig");
const rigs = @import("repository/rigs.zig");
const shutdown_module = @import("shutdown.zig");
const sqlite = @import("repository/sqlite.zig");

const Io = std.Io;

pub const App = struct {
    io: Io,
    config: config_module.Config,
    database: ?sqlite.Database,
    shutdown: shutdown_module.Shutdown,
    server: http_server.HttpServer,

    pub fn init(allocator: std.mem.Allocator, io: Io, config: config_module.Config) !App {
        var database: ?sqlite.Database = if (config.db_path) |path| try sqlite.Database.open(allocator, path) else null;
        errdefer if (database) |*opened| opened.deinit();
        if (database) |*opened| {
            if (!try opened.quickCheck()) return error.DatabaseIntegrityCheckFailed;
            try rigs.initialize(opened);
            std.log.info("SQLite {s} compatibility database opened", .{opened.version()});
        }

        var shutdown = try shutdown_module.Shutdown.init();
        errdefer shutdown.deinit();
        const server = try http_server.HttpServer.init(allocator, io, config);
        return .{
            .io = io,
            .config = config,
            .database = database,
            .shutdown = shutdown,
            .server = server,
        };
    }

    pub fn deinit(app: *App) void {
        app.server.deinit();
        app.shutdown.deinit();
        if (app.database) |*database| database.deinit();
        app.* = undefined;
    }

    pub fn run(app: *App) !void {
        var server_task = try app.io.concurrent(runServer, .{ &app.server, &app.shutdown });
        defer server_task.cancel(app.io) catch |failure| switch (failure) {
            error.Canceled => {},
        };
        std.log.info("controller mode={t} listening on {s}:{d}", .{ app.config.mode, app.config.host, app.config.port });
        try app.shutdown.wait();
        std.log.info("controller shutdown complete", .{});
    }
};

fn runServer(server: *http_server.HttpServer, shutdown: *shutdown_module.Shutdown) Io.Cancelable!void {
    server.run() catch |failure| switch (failure) {
        error.Canceled => return error.Canceled,
        else => std.log.err("controller server stopped: {t}", .{failure}),
    };
    shutdown.request();
}
