const std = @import("std");
const config_module = @import("config.zig");
const http_server_module = @import("http_server.zig");
const shutdown_module = @import("shutdown.zig");
const sqlite = @import("repository/sqlite.zig");

const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const config = try config_module.Config.load(init);
    var repository: ?sqlite.Database = if (config.db_path) |path| try sqlite.Database.open(init.gpa, path) else null;
    defer if (repository) |*database| database.deinit();
    if (repository) |*database| {
        if (!try database.quickCheck()) return error.DatabaseIntegrityCheckFailed;
        std.log.info("SQLite {s} compatibility database opened", .{database.version()});
    }

    var server = try http_server_module.HttpServer.init(init.gpa, init.io, config);
    defer server.deinit();
    var shutdown = try shutdown_module.Shutdown.init();
    defer shutdown.deinit();

    var server_task = try init.io.concurrent(runServer, .{&server});
    std.log.info("controller mode={t} listening on {s}:{d}", .{ config.mode, config.host, config.port });
    try shutdown.wait();
    server_task.cancel(init.io) catch |failure| switch (failure) {
        error.Canceled => {},
    };
    std.log.info("controller shutdown complete", .{});
}

fn runServer(server: *http_server_module.HttpServer) Io.Cancelable!void {
    server.run() catch |failure| switch (failure) {
        error.Canceled => return error.Canceled,
        else => std.log.err("controller server stopped: {t}", .{failure}),
    };
}
