const std = @import("std");
const builtin = @import("builtin");
const config_module = @import("../config.zig");
const runtime_info = @import("runtime_info.zig");

const max_finished_jobs = 50;
const max_jobs = 64;
const max_output_bytes = 8 * 1024 * 1024;
const max_output_tail = 4000;

pub const Options = struct {
    backend: []const u8,
    job_type: []const u8,
    target_id: ?[]const u8 = null,
    version: ?[]const u8 = null,
    prefer_bundled: ?bool = null,
};

const Status = enum { queued, running, success, failed, cancelled };

const Job = struct {
    allocator: std.mem.Allocator,
    id: []u8,
    backend: []u8,
    target_id: ?[]u8,
    job_type: []u8,
    status: Status,
    progress: f64,
    message: []u8,
    command: ?[]u8 = null,
    started_at: []u8,
    finished_at: ?[]u8 = null,
    output_tail: ?[]u8 = null,
    error_message: ?[]u8 = null,
    sequence: u64,
    active_handles: usize = 0,
    process_id: i32 = 0,
    group: std.Io.Group = .init,

    fn deinit(job: *Job) void {
        job.allocator.free(job.id);
        job.allocator.free(job.backend);
        if (job.target_id) |value| job.allocator.free(value);
        job.allocator.free(job.job_type);
        job.allocator.free(job.message);
        if (job.command) |value| job.allocator.free(value);
        job.allocator.free(job.started_at);
        if (job.finished_at) |value| job.allocator.free(value);
        if (job.output_tail) |value| job.allocator.free(value);
        if (job.error_message) |value| job.allocator.free(value);
        job.allocator.destroy(job);
    }
};

pub const State = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    jobs: std.StringHashMapUnmanaged(*Job) = .empty,
    next_sequence: std.atomic.Value(u64) = .init(1),

    pub fn init(allocator: std.mem.Allocator, io: std.Io) State {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(state: *State) void {
        var pointers: [max_jobs]*Job = undefined;
        var count: usize = 0;
        state.mutex.lock(state.io) catch return;
        var iterator = state.jobs.valueIterator();
        while (iterator.next()) |job| {
            if (count < pointers.len) {
                pointers[count] = job.*;
                count += 1;
            }
        }
        state.mutex.unlock(state.io);
        for (pointers[0..count]) |job| {
            if (job.process_id > 0) signalProcessGroup(job.process_id, true);
            job.group.cancel(state.io);
        }
        for (pointers[0..count]) |job| job.deinit();
        state.jobs.deinit(state.allocator);
        state.* = undefined;
    }

    pub fn createPayload(state: *State, configuration: *const config_module.Config, cache: *runtime_info.Cache, options: Options, legacy: bool) ![]u8 {
        if (!validBackend(options.backend) or !validType(options.job_type)) return error.InvalidJobPayload;
        if (options.version) |version| if (!validVersion(version)) return error.InvalidJobPayload;
        try state.pruneFinished();
        const job = try state.createJob(options);
        var job_owned = true;
        defer if (job_owned) job.deinit();
        const response = try serializeEnvelope(state.allocator, job, legacy);
        errdefer state.allocator.free(response);
        try state.mutex.lock(state.io);
        var locked = true;
        defer if (locked) state.mutex.unlock(state.io);
        if (state.jobs.count() >= max_jobs) return error.TooManyRuntimeJobs;
        const entry = try state.jobs.getOrPut(state.allocator, job.id);
        if (entry.found_existing) {
            return error.JobIdentityCollision;
        }
        entry.value_ptr.* = job;
        job_owned = false;
        state.mutex.unlock(state.io);
        locked = false;
        job.group.concurrent(state.io, runJob, .{ state, configuration, cache, job.id }) catch |failure| {
            if (state.mutex.lock(state.io)) |_| {
                if (state.jobs.remove(job.id)) job_owned = true;
                state.mutex.unlock(state.io);
            } else |_| {}
            return failure;
        };
        return response;
    }

    pub fn listPayload(state: *State) ![]u8 {
        try state.mutex.lock(state.io);
        defer state.mutex.unlock(state.io);
        const pointers = try state.allocator.alloc(*Job, state.jobs.count());
        defer state.allocator.free(pointers);
        var iterator = state.jobs.valueIterator();
        var index: usize = 0;
        while (iterator.next()) |job| : (index += 1) pointers[index] = job.*;
        std.mem.sort(*Job, pointers, {}, newerFirst);
        var output: std.Io.Writer.Allocating = .init(state.allocator);
        errdefer output.deinit();
        try output.writer.writeAll("{\"jobs\":[");
        for (pointers, 0..) |job, job_index| {
            if (job_index > 0) try output.writer.writeByte(',');
            try writeJob(&output.writer, job);
        }
        try output.writer.writeAll("]}");
        return output.toOwnedSlice();
    }

    pub fn onePayload(state: *State, id: []const u8) !?[]u8 {
        try state.mutex.lock(state.io);
        defer state.mutex.unlock(state.io);
        const job = state.jobs.get(id) orelse return null;
        return @as(?[]u8, try serializeEnvelope(state.allocator, job, false));
    }

    pub fn cancelPayload(state: *State, id: []const u8) !?[]u8 {
        try state.mutex.lock(state.io);
        var locked = true;
        defer if (locked) state.mutex.unlock(state.io);
        const job = state.jobs.get(id) orelse {
            return null;
        };
        const should_cancel = job.status == .queued or job.status == .running;
        if (should_cancel) {
            try replaceString(job.allocator, &job.message, try job.allocator.dupe(u8, "cancelled by user"));
            job.status = .cancelled;
            job.progress = 1;
            try setOptionalString(job.allocator, &job.finished_at, try nowTimestamp(job.allocator, state.io));
            job.active_handles += 1;
        } else {
            return @as(?[]u8, try serializeEnvelope(state.allocator, job, false));
        }
        state.mutex.unlock(state.io);
        locked = false;
        if (job.process_id > 0) signalProcessGroup(job.process_id, false);
        state.io.sleep(.fromSeconds(2), .awake) catch {};
        try state.mutex.lock(state.io);
        const current_process_id = job.process_id;
        if (current_process_id > 0) signalProcessGroup(current_process_id, true);
        state.mutex.unlock(state.io);
        job.group.cancel(state.io);
        try state.mutex.lock(state.io);
        defer state.mutex.unlock(state.io);
        const current = state.jobs.get(id) orelse return null;
        current.active_handles -= 1;
        return @as(?[]u8, try serializeEnvelope(state.allocator, current, false));
    }

    fn createJob(state: *State, options: Options) !*Job {
        const job = try state.allocator.create(Job);
        errdefer state.allocator.destroy(job);
        const id = try randomId(state.allocator, state.io);
        errdefer state.allocator.free(id);
        const backend = try state.allocator.dupe(u8, options.backend);
        errdefer state.allocator.free(backend);
        const target_id = if (options.target_id) |value| try state.allocator.dupe(u8, value) else null;
        errdefer if (target_id) |value| state.allocator.free(value);
        const job_type = try state.allocator.dupe(u8, options.job_type);
        errdefer state.allocator.free(job_type);
        const message = try std.fmt.allocPrint(state.allocator, "{s} queued for {s}", .{ options.job_type, options.backend });
        errdefer state.allocator.free(message);
        const started_at = try nowTimestamp(state.allocator, state.io);
        errdefer state.allocator.free(started_at);
        const sequence = state.next_sequence.fetchAdd(1, .monotonic);
        job.* = .{
            .allocator = state.allocator,
            .id = id,
            .backend = backend,
            .target_id = target_id,
            .job_type = job_type,
            .status = .queued,
            .progress = 0,
            .message = message,
            .started_at = started_at,
            .sequence = sequence,
        };
        return job;
    }

    fn pruneFinished(state: *State) !void {
        try state.mutex.lock(state.io);
        defer state.mutex.unlock(state.io);
        while (finishedCount(state) > max_finished_jobs) {
            var oldest: ?*Job = null;
            var iterator = state.jobs.valueIterator();
            while (iterator.next()) |candidate| {
                if (!finished(candidate.*.status) or candidate.*.active_handles > 0) continue;
                if (oldest == null or candidate.*.sequence < oldest.?.sequence) oldest = candidate.*;
            }
            const job = oldest orelse break;
            _ = state.jobs.remove(job.id);
            job.group.cancel(state.io);
            job.deinit();
        }
    }
};

fn runJob(state: *State, configuration: *const config_module.Config, cache: *runtime_info.Cache, id: []const u8) void {
    runJobInner(state, configuration, cache, id) catch |failure| {
        if (failure == error.Canceled) {
            markCancelled(state, id);
        } else {
            markFailed(state, id, @errorName(failure));
        }
    };
}

fn runJobInner(state: *State, configuration: *const config_module.Config, cache: *runtime_info.Cache, id: []const u8) !void {
    const command = command: {
        try state.mutex.lock(state.io);
        defer state.mutex.unlock(state.io);
        const job = state.jobs.get(id) orelse {
            return;
        };
        if (job.status != .queued) return;
        const environment_name = upgradeEnvironment(job.backend) orelse {
            try failJobLocked(job, state.io, try std.fmt.allocPrint(job.allocator, "No {s} upgrade command configured.", .{job.backend}));
            return;
        };
        const configured = configuration.environment.get(environment_name) orelse {
            try failJobLocked(job, state.io, try std.fmt.allocPrint(job.allocator, "No {s} upgrade command configured. Set {s}.", .{ job.backend, environment_name }));
            return;
        };
        const trimmed = std.mem.trim(u8, configured, " \t\r\n");
        if (trimmed.len == 0) {
            try failJobLocked(job, state.io, try job.allocator.dupe(u8, "Upgrade command is empty"));
            return;
        }
        const owned = try state.allocator.dupe(u8, trimmed);
        errdefer state.allocator.free(owned);
        const message = try std.fmt.allocPrint(job.allocator, "{s} running for {s}", .{ job.job_type, job.backend });
        try replaceString(job.allocator, &job.message, message);
        job.status = .running;
        job.progress = 0.05;
        try setOptionalString(job.allocator, &job.command, try job.allocator.dupe(u8, trimmed));
        break :command owned;
    };
    defer state.allocator.free(command);
    const result = runCommand(state, configuration, id, command) catch |failure| switch (failure) {
        error.Canceled => return error.Canceled,
        error.Timeout => return markFailed(state, id, "Upgrade command timed out after 10 minutes"),
        error.StreamTooLong => return markFailed(state, id, "Upgrade command output exceeded 8 MiB"),
        else => return markFailed(state, id, @errorName(failure)),
    };
    defer state.allocator.free(result.stdout);
    defer state.allocator.free(result.stderr);
    const output = if (result.stdout.len > 0) result.stdout else result.stderr;
    const success = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!success) return markFailedWithOutput(state, id, if (result.stderr.len > 0) result.stderr else "Upgrade command failed", output);
    try cache.invalidate();
    try state.mutex.lock(state.io);
    defer state.mutex.unlock(state.io);
    const job = state.jobs.get(id) orelse return;
    if (job.status != .running) return;
    const message = try std.fmt.allocPrint(job.allocator, "{s} complete", .{job.job_type});
    try replaceString(job.allocator, &job.message, message);
    job.status = .success;
    job.progress = 1;
    try setOptionalString(job.allocator, &job.finished_at, try nowTimestamp(job.allocator, state.io));
    if (tail(output)) |value| try setOptionalString(job.allocator, &job.output_tail, try job.allocator.dupe(u8, value));
}

const CommandResult = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
};

fn runCommand(state: *State, configuration: *const config_module.Config, id: []const u8, command: []const u8) !CommandResult {
    var child = try std.process.spawn(state.io, .{
        .argv = &.{command},
        .environ_map = configuration.environment,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = 0,
    });
    const process_id: i32 = @intCast(child.id orelse return error.SpawnFailed);
    defer if (child.id != null) {
        signalProcessGroup(process_id, true);
        child.kill(state.io);
    };
    try state.mutex.lock(state.io);
    const job = state.jobs.get(id) orelse {
        state.mutex.unlock(state.io);
        return error.Canceled;
    };
    if (job.status != .running) {
        state.mutex.unlock(state.io);
        return error.Canceled;
    }
    job.process_id = process_id;
    state.mutex.unlock(state.io);
    defer clearProcessId(state, id, process_id);

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(state.allocator, state.io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();
    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);
    const timeout: std.Io.Timeout = .{ .duration = .{ .clock = .awake, .raw = std.Io.Duration.fromSeconds(600) } };
    while (multi_reader.fill(64, timeout)) |_| {
        if (stdout_reader.buffered().len > max_output_bytes or stderr_reader.buffered().len > max_output_bytes) return error.StreamTooLong;
    } else |failure| switch (failure) {
        error.EndOfStream => {},
        else => |other| return other,
    }
    try multi_reader.checkAnyError();
    const term = try child.wait(state.io);
    const stdout = try multi_reader.toOwnedSlice(0);
    errdefer state.allocator.free(stdout);
    const stderr = try multi_reader.toOwnedSlice(1);
    return .{ .term = term, .stdout = stdout, .stderr = stderr };
}

fn clearProcessId(state: *State, id: []const u8, process_id: i32) void {
    const previous_protection = state.io.swapCancelProtection(.blocked);
    defer _ = state.io.swapCancelProtection(previous_protection);
    state.mutex.lock(state.io) catch return;
    defer state.mutex.unlock(state.io);
    const job = state.jobs.get(id) orelse return;
    if (job.process_id == process_id) job.process_id = 0;
}

fn signalProcessGroup(process_id: i32, force: bool) void {
    switch (builtin.os.tag) {
        .windows, .wasi => {},
        else => {
            const signal: std.posix.SIG = if (force) .KILL else .TERM;
            std.posix.kill(-@as(std.posix.pid_t, @intCast(process_id)), signal) catch {};
        },
    }
}

fn failJobLocked(job: *Job, io: std.Io, message: []u8) !void {
    try replaceString(job.allocator, &job.message, message);
    try setOptionalString(job.allocator, &job.error_message, try job.allocator.dupe(u8, message));
    try setOptionalString(job.allocator, &job.output_tail, try job.allocator.dupe(u8, tail(message) orelse message));
    job.status = .failed;
    job.progress = 1;
    try setOptionalString(job.allocator, &job.finished_at, try nowTimestamp(job.allocator, io));
}

fn markCancelled(state: *State, id: []const u8) void {
    state.mutex.lock(state.io) catch return;
    defer state.mutex.unlock(state.io);
    const job = state.jobs.get(id) orelse return;
    if (finished(job.status)) return;
    replaceString(job.allocator, &job.message, job.allocator.dupe(u8, "cancelled by user") catch return) catch return;
    job.status = .cancelled;
    job.progress = 1;
    setOptionalString(job.allocator, &job.finished_at, nowTimestamp(job.allocator, state.io) catch return) catch return;
}

fn markFailed(state: *State, id: []const u8, message: []const u8) void {
    markFailedWithOutput(state, id, message, message);
}

fn markFailedWithOutput(state: *State, id: []const u8, message: []const u8, output: []const u8) void {
    state.mutex.lock(state.io) catch return;
    defer state.mutex.unlock(state.io);
    const job = state.jobs.get(id) orelse return;
    if (job.status == .cancelled or job.status == .success) return;
    replaceString(job.allocator, &job.message, job.allocator.dupe(u8, message) catch return) catch return;
    setOptionalString(job.allocator, &job.error_message, job.allocator.dupe(u8, message) catch return) catch return;
    if (tail(output)) |value| setOptionalString(job.allocator, &job.output_tail, job.allocator.dupe(u8, value) catch return) catch return;
    job.status = .failed;
    job.progress = 1;
    setOptionalString(job.allocator, &job.finished_at, nowTimestamp(job.allocator, state.io) catch return) catch return;
}

fn serializeEnvelope(allocator: std.mem.Allocator, job: *const Job, legacy: bool) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    if (legacy) {
        try output.writer.writeAll("{\"job_id\":");
        try std.json.Stringify.value(job.id, .{}, &output.writer);
        try output.writer.writeAll(",\"job\":");
    } else try output.writer.writeAll("{\"job\":");
    try writeJob(&output.writer, job);
    try output.writer.writeByte('}');
    return output.toOwnedSlice();
}

fn writeJob(writer: *std.Io.Writer, job: *const Job) !void {
    try writer.writeAll("{\"id\":");
    try std.json.Stringify.value(job.id, .{}, writer);
    try writer.writeAll(",\"backend\":");
    try std.json.Stringify.value(job.backend, .{}, writer);
    if (job.target_id) |target_id| {
        try writer.writeAll(",\"targetId\":");
        try std.json.Stringify.value(target_id, .{}, writer);
    }
    try writer.writeAll(",\"type\":");
    try std.json.Stringify.value(job.job_type, .{}, writer);
    try writer.writeAll(",\"status\":");
    try std.json.Stringify.value(if (job.status == .failed) "error" else @tagName(job.status), .{}, writer);
    try writer.print(",\"progress\":{d},\"message\":", .{job.progress});
    try std.json.Stringify.value(job.message, .{}, writer);
    if (job.command) |value| {
        try writer.writeAll(",\"command\":");
        try std.json.Stringify.value(value, .{}, writer);
    }
    try writer.writeAll(",\"startedAt\":");
    try std.json.Stringify.value(job.started_at, .{}, writer);
    if (job.finished_at) |value| {
        try writer.writeAll(",\"finishedAt\":");
        try std.json.Stringify.value(value, .{}, writer);
    }
    if (job.output_tail) |value| {
        try writer.writeAll(",\"outputTail\":");
        try std.json.Stringify.value(value, .{}, writer);
    }
    if (job.error_message) |value| {
        try writer.writeAll(",\"error\":");
        try std.json.Stringify.value(value, .{}, writer);
    }
    try writer.writeByte('}');
}

fn validBackend(value: []const u8) bool {
    for ([_][]const u8{ "vllm", "sglang", "llamacpp", "mlx", "cuda", "rocm" }) |backend| if (std.mem.eql(u8, value, backend)) return true;
    return false;
}

fn validType(value: []const u8) bool {
    return std.mem.eql(u8, value, "install") or std.mem.eql(u8, value, "update");
}

fn validVersion(value: []const u8) bool {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > 128 or trimmed[0] == '-') return false;
    for (trimmed) |character| if (!std.ascii.isAlphanumeric(character) and character != '.' and character != '+' and character != '-' and character != '_') return false;
    return true;
}

fn upgradeEnvironment(backend: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, backend, "vllm")) return "LOCAL_STUDIO_VLLM_UPGRADE_CMD";
    if (std.mem.eql(u8, backend, "sglang")) return "LOCAL_STUDIO_SGLANG_UPGRADE_CMD";
    if (std.mem.eql(u8, backend, "llamacpp")) return "LOCAL_STUDIO_LLAMACPP_UPGRADE_CMD";
    if (std.mem.eql(u8, backend, "cuda")) return "LOCAL_STUDIO_CUDA_UPGRADE_CMD";
    if (std.mem.eql(u8, backend, "rocm")) return "LOCAL_STUDIO_ROCM_UPGRADE_CMD";
    return null;
}

fn finished(status: Status) bool {
    return status == .success or status == .failed or status == .cancelled;
}

fn finishedCount(state: *const State) usize {
    var count: usize = 0;
    var iterator = state.jobs.valueIterator();
    while (iterator.next()) |job| if (finished(job.*.status)) {
        count += 1;
    };
    return count;
}

fn newerFirst(_: void, left: *Job, right: *Job) bool {
    return left.sequence > right.sequence;
}

fn replaceString(allocator: std.mem.Allocator, target: *[]u8, replacement: []u8) !void {
    allocator.free(target.*);
    target.* = replacement;
}

fn setOptionalString(allocator: std.mem.Allocator, target: *?[]u8, replacement: []u8) !void {
    if (target.*) |value| allocator.free(value);
    target.* = replacement;
}

fn tail(value: []const u8) ?[]const u8 {
    if (value.len == 0) return null;
    return value[value.len - @min(value.len, max_output_tail) ..];
}

fn randomId(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    var bytes: [16]u8 = undefined;
    io.random(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    return std.fmt.allocPrint(allocator, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15] });
}

fn nowTimestamp(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const seconds = std.Io.Clock.real.now(io).toSeconds();
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(seconds, 0)) };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.000Z", .{ year_day.year, month_day.month.numeric(), month_day.day_index + 1, day_seconds.getHoursIntoDay(), day_seconds.getMinutesIntoHour(), day_seconds.getSecondsIntoMinute() });
}
