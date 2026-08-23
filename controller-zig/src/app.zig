const std = @import("std");
const config_module = @import("config.zig");
const http_server = @import("http_server.zig");
const system_info = @import("platform/system_info.zig");
const controller_settings = @import("repository/controller_settings.zig");
const rig_node_credentials = @import("repository/rig_node_credentials.zig");
const rigs = @import("repository/rigs.zig");
const recipes = @import("repository/recipes.zig");
const peak_metrics = @import("repository/peak_metrics.zig");
const shutdown_module = @import("shutdown.zig");
const sqlite = @import("repository/sqlite.zig");
const workers = @import("services/workers.zig");
const lifecycle = @import("services/lifecycle.zig");
const runtime_info = @import("services/runtime_info.zig");

const Io = std.Io;

pub const App = struct {
    io: Io,
    config: config_module.Config,
    database: sqlite.Database,
    recipe_column: recipes.PayloadColumn,
    system: system_info.Snapshot,
    worker_pool: workers.Pool,
    supervisor: lifecycle.Supervisor,
    runtime_cache: runtime_info.Cache,
    shutdown: shutdown_module.Shutdown,
    server: http_server.HttpServer,

    pub fn init(allocator: std.mem.Allocator, io: Io, config: config_module.Config) !App {
        _ = try std.Io.Dir.cwd().createDirPathStatus(io, config.data_dir, @enumFromInt(0o700));
        var database = try sqlite.Database.open(allocator, config.db_path);
        errdefer database.deinit();
        if (!try database.quickCheck()) return error.DatabaseIntegrityCheckFailed;
        try rigs.initialize(&database);
        try rig_node_credentials.initialize(&database);
        try controller_settings.initialize(&database);
        try peak_metrics.initialize(&database);
        const recipe_column = try recipes.initialize(&database);
        std.log.info("SQLite {s} compatibility database opened", .{database.version()});

        var system = try system_info.detect(allocator);
        errdefer system.deinit();

        var shutdown = try shutdown_module.Shutdown.init();
        errdefer shutdown.deinit();
        var worker_pool = workers.Pool.init(allocator);
        errdefer worker_pool.deinit();
        var supervisor = lifecycle.Supervisor.init(allocator, io, config.data_dir, config.llm_instance_path);
        errdefer supervisor.deinit();
        var runtime_cache = runtime_info.Cache.init(allocator, io);
        errdefer runtime_cache.deinit();
        const server = try http_server.HttpServer.init(allocator, io, config);
        return .{
            .io = io,
            .config = config,
            .database = database,
            .recipe_column = recipe_column,
            .system = system,
            .worker_pool = worker_pool,
            .supervisor = supervisor,
            .runtime_cache = runtime_cache,
            .shutdown = shutdown,
            .server = server,
        };
    }

    pub fn deinit(app: *App) void {
        app.server.deinit();
        app.shutdown.deinit();
        app.system.deinit();
        app.worker_pool.deinit();
        app.supervisor.deinit();
        app.runtime_cache.deinit();
        app.database.deinit();
        app.config.deinit();
        app.* = undefined;
    }

    pub fn run(app: *App) !void {
        var supervisor_task = try app.io.concurrent(runSupervisor, .{&app.supervisor});
        defer supervisor_task.cancel(app.io) catch |failure| switch (failure) {
            error.Canceled => {},
        };
        var server_task = try app.io.concurrent(runServer, .{ &app.server, &app.database, app.recipe_column, &app.system, &app.worker_pool, &app.supervisor, &app.runtime_cache, &app.shutdown });
        defer server_task.cancel(app.io) catch |failure| switch (failure) {
            error.Canceled => {},
        };
        std.log.info("controller mode={t} node={s} listening on {s}:{d}", .{ app.config.mode, app.system.hostname, app.config.host, app.config.port });
        try app.shutdown.wait();
        if (app.config.mode != .head) _ = app.supervisor.evict() catch |failure| std.log.err("engine shutdown failed: {t}", .{failure});
        std.log.info("controller shutdown complete", .{});
    }
};

fn runSupervisor(supervisor: *lifecycle.Supervisor) Io.Cancelable!void {
    return supervisor.run();
}

fn runServer(server: *http_server.HttpServer, database: *sqlite.Database, recipe_column: recipes.PayloadColumn, system: *const system_info.Snapshot, worker_pool: *workers.Pool, supervisor: *lifecycle.Supervisor, runtime_cache: *runtime_info.Cache, shutdown: *shutdown_module.Shutdown) Io.Cancelable!void {
    server.run(database, recipe_column, system, worker_pool, supervisor, runtime_cache) catch |failure| switch (failure) {
        error.Canceled => return error.Canceled,
        else => std.log.err("controller server stopped: {t}", .{failure}),
    };
    shutdown.request();
}
