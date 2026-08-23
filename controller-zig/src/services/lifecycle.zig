const std = @import("std");
const instances = @import("../repository/instances.zig");
const recipe_repository = @import("../repository/recipes.zig");
const sqlite = @import("../repository/sqlite.zig");
const launch_plan = @import("launch_plan.zig");
const processes = @import("processes.zig");
const recipes = @import("recipes.zig");

const Io = std.Io;
const http = std.http;

pub const Supervisor = struct {
    allocator: std.mem.Allocator,
    io: Io,
    data_dir: []const u8,
    instance_path: []const u8,
    mutex: Io.Mutex = .init,
    children: Io.Group = .init,
    cancel_requested: std.atomic.Value(bool) = .init(false),

    pub fn init(allocator: std.mem.Allocator, io: Io, data_dir: []const u8, instance_path: []const u8) Supervisor {
        return .{
            .allocator = allocator,
            .io = io,
            .data_dir = data_dir,
            .instance_path = instance_path,
        };
    }

    pub fn deinit(supervisor: *Supervisor) void {
        supervisor.children.cancel(supervisor.io);
        supervisor.* = undefined;
    }

    pub fn launch(supervisor: *Supervisor, client: *http.Client, database: *sqlite.Database, recipe_column: recipe_repository.PayloadColumn, recipe_id: []const u8, default_trust_remote_code: bool, base_environment: *const std.process.Environ.Map) !void {
        const document = try recipes.detailPayload(supervisor.allocator, supervisor.io, database, recipe_column, recipe_id, default_trust_remote_code) orelse return error.RecipeNotFound;
        defer supervisor.allocator.free(document);
        var plan = try launch_plan.build(supervisor.allocator, document);
        defer plan.deinit();

        try supervisor.mutex.lock(supervisor.io);
        var locked = true;
        defer if (locked) supervisor.mutex.unlock(supervisor.io);
        if (try instances.readLlm(supervisor.allocator, supervisor.io, supervisor.instance_path)) |record_value| {
            var record = record_value;
            defer record.deinit();
            if (processes.owns(supervisor.allocator, supervisor.io, &record)) return error.AlreadyRunning;
            try instances.dropLlm(supervisor.io, supervisor.instance_path);
        }

        var nonce_bytes: [16]u8 = undefined;
        supervisor.io.random(&nonce_bytes);
        const nonce_buffer = std.fmt.bytesToHex(nonce_bytes, .lower);
        const nonce = nonce_buffer[0..];
        supervisor.cancel_requested.store(false, .release);
        if (!portBindable(supervisor.io, plan.port)) return error.PortInUse;
        try instances.writeReservation(supervisor.io, supervisor.instance_path, plan.recipe_id, plan.backend, plan.port, nonce, plan.ready_timeout_seconds);
        var record_requires_cleanup = true;
        errdefer if (record_requires_cleanup) instances.dropLlm(supervisor.io, supervisor.instance_path) catch {};
        if (supervisor.cancel_requested.load(.acquire)) return error.LaunchCancelled;

        const logs_dir = try std.fs.path.join(supervisor.allocator, &.{ supervisor.data_dir, "instances", "logs" });
        defer supervisor.allocator.free(logs_dir);
        _ = try std.Io.Dir.cwd().createDirPathStatus(supervisor.io, logs_dir, @enumFromInt(0o700));
        const log_path = try std.fs.path.join(supervisor.allocator, &.{ logs_dir, "llm.log" });
        defer supervisor.allocator.free(log_path);
        var log_file = try std.Io.Dir.cwd().createFile(supervisor.io, log_path, .{ .permissions = @enumFromInt(0o600) });
        defer log_file.close(supervisor.io);

        var environment = try base_environment.clone(supervisor.allocator);
        defer environment.deinit();
        for (plan.environment) |entry| try environment.put(entry.key, entry.value);
        try environment.put("LOCAL_STUDIO_LAUNCH_NONCE", nonce);

        var child = try std.process.spawn(supervisor.io, .{
            .argv = plan.argv,
            .environ_map = &environment,
            .stdin = .ignore,
            .stdout = .{ .file = log_file },
            .stderr = .{ .file = log_file },
            .pgid = 0,
        });
        var child_transferred = false;
        errdefer if (!child_transferred) child.kill(supervisor.io);
        const pid: i32 = @intCast(child.id orelse return error.SpawnFailed);
        const reference = capture: {
            var attempts: usize = 0;
            while (attempts < 20) : (attempts += 1) {
                if (processes.capture(supervisor.allocator, supervisor.io, pid)) |captured| break :capture captured else |_| {}
                try supervisor.io.sleep(.fromMilliseconds(25), .awake);
            }
            return error.ProcessIdentityUnavailable;
        };
        defer if (reference.start_token) |token| supervisor.allocator.free(token);
        if (supervisor.cancel_requested.load(.acquire)) return error.LaunchCancelled;
        try instances.writeProcess(supervisor.io, supervisor.instance_path, plan.recipe_id, plan.backend, plan.port, nonce, reference, plan.ready_timeout_seconds);

        const reaper_nonce = try supervisor.allocator.dupe(u8, nonce);
        supervisor.children.concurrent(supervisor.io, reapChild, .{ supervisor, child, pid, reaper_nonce }) catch |failure| {
            supervisor.allocator.free(reaper_nonce);
            return failure;
        };
        child_transferred = true;
        locked = false;
        supervisor.mutex.unlock(supervisor.io);

        const deadline = Io.Clock.awake.now(supervisor.io).addDuration(.fromSeconds(@intCast(plan.ready_timeout_seconds)));
        while (Io.Clock.awake.now(supervisor.io).durationTo(deadline).toNanoseconds() > 0) {
            if (supervisor.cancel_requested.load(.acquire)) {
                _ = try supervisor.evict();
                return error.LaunchCancelled;
            }
            const record_value = try instances.readLlm(supervisor.allocator, supervisor.io, supervisor.instance_path) orelse return error.ProcessExitedEarly;
            var record = record_value;
            defer record.deinit();
            if (!processes.owns(supervisor.allocator, supervisor.io, &record)) return error.ProcessExitedEarly;
            if (try healthy(supervisor.allocator, supervisor.io, client, record.port, plan.health_path)) {
                record_requires_cleanup = false;
                return;
            }
            try supervisor.io.sleep(.fromSeconds(2), .awake);
        }
        _ = try supervisor.evict();
        return error.ReadinessTimeout;
    }

    pub fn cancelLaunch(supervisor: *Supervisor) !bool {
        const record = try instances.readLlm(supervisor.allocator, supervisor.io, supervisor.instance_path) orelse return false;
        defer {
            var mutable = record;
            mutable.deinit();
        }
        supervisor.cancel_requested.store(true, .release);
        return true;
    }

    pub fn evict(supervisor: *Supervisor) !bool {
        try supervisor.mutex.lock(supervisor.io);
        defer supervisor.mutex.unlock(supervisor.io);
        const record_value = try instances.readLlm(supervisor.allocator, supervisor.io, supervisor.instance_path) orelse return false;
        var record = record_value;
        defer record.deinit();
        if (!processes.owns(supervisor.allocator, supervisor.io, &record)) {
            try instances.dropLlm(supervisor.io, supervisor.instance_path);
            return false;
        }
        _ = try processes.terminateOwned(supervisor.allocator, supervisor.io, &record, .TERM);
        var attempts: usize = 0;
        while (attempts < 100) : (attempts += 1) {
            if (!processes.owns(supervisor.allocator, supervisor.io, &record)) break;
            try supervisor.io.sleep(.fromMilliseconds(200), .awake);
        }
        if (processes.owns(supervisor.allocator, supervisor.io, &record)) _ = try processes.terminateOwned(supervisor.allocator, supervisor.io, &record, .KILL);
        try instances.dropLlm(supervisor.io, supervisor.instance_path);
        supervisor.cancel_requested.store(false, .release);
        return true;
    }

    pub fn waitReady(supervisor: *Supervisor, client: *http.Client, timeout_seconds: u64) !bool {
        const deadline = Io.Clock.awake.now(supervisor.io).addDuration(.fromSeconds(@intCast(timeout_seconds)));
        while (Io.Clock.awake.now(supervisor.io).durationTo(deadline).toNanoseconds() > 0) {
            const record_value = try instances.readLlm(supervisor.allocator, supervisor.io, supervisor.instance_path) orelse return false;
            var record = record_value;
            defer record.deinit();
            if (!processes.owns(supervisor.allocator, supervisor.io, &record)) return false;
            const health_path = if (std.mem.eql(u8, record.engine, "mlx")) "/v1/models" else "/health";
            if (try healthy(supervisor.allocator, supervisor.io, client, record.port, health_path)) return true;
            try supervisor.io.sleep(.fromSeconds(2), .awake);
        }
        return false;
    }

    pub fn run(supervisor: *Supervisor) Io.Cancelable!void {
        while (true) {
            supervisor.superviseOnce() catch |failure| switch (failure) {
                error.Canceled => return error.Canceled,
                else => std.log.err("instance supervision failed: {t}", .{failure}),
            };
            try supervisor.io.sleep(.fromSeconds(2), .awake);
        }
    }

    fn superviseOnce(supervisor: *Supervisor) !void {
        try supervisor.mutex.lock(supervisor.io);
        defer supervisor.mutex.unlock(supervisor.io);
        const record_value = try instances.readLlm(supervisor.allocator, supervisor.io, supervisor.instance_path) orelse return;
        var record = record_value;
        defer record.deinit();
        if (!processes.owns(supervisor.allocator, supervisor.io, &record)) try instances.dropLlm(supervisor.io, supervisor.instance_path);
    }
};

fn reapChild(supervisor: *Supervisor, child_value: std.process.Child, pid: i32, expected_nonce: []u8) Io.Cancelable!void {
    defer supervisor.allocator.free(expected_nonce);
    defer cleanupChildRecord(supervisor, pid, expected_nonce);
    var child = child_value;
    defer child.kill(supervisor.io);
    _ = child.wait(supervisor.io) catch |failure| switch (failure) {
        error.Canceled => return error.Canceled,
        else => return,
    };
}

fn cleanupChildRecord(supervisor: *Supervisor, pid: i32, expected_nonce: []const u8) void {
    const previous_protection = supervisor.io.swapCancelProtection(.blocked);
    defer _ = supervisor.io.swapCancelProtection(previous_protection);
    supervisor.mutex.lock(supervisor.io) catch return;
    defer supervisor.mutex.unlock(supervisor.io);
    const record_value = instances.readLlm(supervisor.allocator, supervisor.io, supervisor.instance_path) catch return;
    if (record_value) |loaded| {
        var record = loaded;
        defer record.deinit();
        const reference = record.process orelse return;
        if (reference.pid == pid and std.mem.eql(u8, record.nonce, expected_nonce)) {
            instances.dropLlm(supervisor.io, supervisor.instance_path) catch {};
        }
    }
}

fn healthy(allocator: std.mem.Allocator, io: Io, client: *http.Client, port: u16, path: []const u8) !bool {
    const FetchResult = anyerror!bool;
    const TimerResult = Io.Cancelable!void;
    const Selection = union(enum) {
        fetch: FetchResult,
        timer: TimerResult,
    };
    var selections: [2]Selection = undefined;
    var select = Io.Select(Selection).init(io, &selections);
    try select.concurrent(.fetch, fetchHealth, .{ allocator, client, port, path });
    select.concurrent(.timer, healthTimeout, .{io}) catch {
        select.cancelDiscard();
        return false;
    };
    const selected = try select.await();
    switch (selected) {
        .fetch => |result| {
            select.cancelDiscard();
            return result catch false;
        },
        .timer => |result| {
            result catch |failure| switch (failure) {
                error.Canceled => return error.Canceled,
            };
            select.cancelDiscard();
            return false;
        },
    }
}

fn healthTimeout(io: Io) Io.Cancelable!void {
    return io.sleep(.fromSeconds(3), .awake);
}

fn fetchHealth(allocator: std.mem.Allocator, client: *http.Client, port: u16, path: []const u8) !bool {
    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}{s}", .{ port, path });
    defer allocator.free(url);
    var storage: [64 * 1024]u8 = undefined;
    var output: Io.Writer = .fixed(&storage);
    const response = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .redirect_behavior = .unhandled,
        .keep_alive = false,
        .headers = .{ .accept_encoding = .omit },
        .response_writer = &output,
    }) catch return false;
    const status = @intFromEnum(response.status);
    return status >= 200 and status < 300;
}

fn portBindable(io: Io, port: u16) bool {
    for ([_][]const u8{ "127.0.0.1", "0.0.0.0" }) |host| {
        const address = std.Io.net.IpAddress.parse(host, port) catch return false;
        var listener = address.listen(io, .{}) catch return false;
        listener.deinit(io);
    }
    return true;
}
