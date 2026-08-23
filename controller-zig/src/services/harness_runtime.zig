const std = @import("std");
const config_module = @import("../config.zig");
const pi_model_route = @import("pi_model_route.zig");

const Io = std.Io;
const max_event_bytes = 16 * 1024 * 1024;
const max_events = 4000;
const LoggedEvent = struct {
    allocator: std.mem.Allocator,
    seq: u64,
    document: []u8,
    timestamp: [24]u8,

    fn deinit(event: *LoggedEvent) void {
        event.allocator.free(event.document);
        event.* = undefined;
    }
};
const Session = struct {
    allocator: std.mem.Allocator,
    id: []u8,
    model_id: []u8,
    cwd: []u8,
    session_dir: []u8,
    child: std.process.Child,
    running: bool = true,
    active: bool = false,
    event_seq: u64 = 0,
    last_error: ?[]u8 = null,
    events: std.ArrayList(LoggedEvent) = .empty,
    responses: std.StringHashMapUnmanaged([]u8) = .empty,

    fn deinit(session: *Session, io: Io) void {
        if (session.child.id != null) session.child.kill(io);
        session.allocator.free(session.id);
        session.allocator.free(session.model_id);
        session.allocator.free(session.cwd);
        session.allocator.free(session.session_dir);
        if (session.last_error) |value| session.allocator.free(value);
        for (session.events.items) |*event| event.deinit();
        session.events.deinit(session.allocator);
        var response_iterator = session.responses.iterator();
        while (response_iterator.next()) |entry| {
            session.allocator.free(entry.key_ptr.*);
            session.allocator.free(entry.value_ptr.*);
        }
        session.responses.deinit(session.allocator);
        session.allocator.destroy(session);
    }
};
pub const Manager = struct {
    allocator: std.mem.Allocator,
    io: Io,
    mode: config_module.Mode,
    environment: *const std.process.Environ.Map,
    data_dir: []u8,
    pi_binary: []u8,
    model_route: pi_model_route.Config,
    mutex: Io.Mutex = .init,
    tasks: Io.Group = .init,
    sessions: std.StringHashMapUnmanaged(*Session) = .empty,
    pub fn init(allocator: std.mem.Allocator, io: Io, configuration: *const config_module.Config) !Manager {
        const configured = configuration.environment.get("LOCAL_STUDIO_PI_BIN") orelse "pi";
        var model_route = try pi_model_route.Config.init(allocator, io, configuration);
        errdefer model_route.deinit();
        return .{
            .allocator = allocator,
            .io = io,
            .mode = configuration.mode,
            .environment = configuration.environment,
            .data_dir = try allocator.dupe(u8, configuration.data_dir),
            .pi_binary = try allocator.dupe(u8, std.mem.trim(u8, configured, " \t\r\n")),
            .model_route = model_route,
        };
    }
    pub fn deinit(manager: *Manager) void {
        manager.tasks.cancel(manager.io);
        var iterator = manager.sessions.valueIterator();
        while (iterator.next()) |session| session.*.deinit(manager.io);
        manager.sessions.deinit(manager.allocator);
        manager.allocator.free(manager.data_dir);
        manager.allocator.free(manager.pi_binary);
        manager.model_route.deinit();
        manager.* = undefined;
    }
    pub fn setupPayload(manager: *Manager) ![]u8 {
        const available = manager.piIsAvailable();
        var output: Io.Writer.Allocating = .init(manager.allocator);
        errdefer output.deinit();
        try output.writer.writeAll("{\"checks\":[{\"id\":\"pi-rpc\",\"label\":\"Pi RPC harness\",\"ok\":");
        try output.writer.print("{},\"value\":", .{available});
        try std.json.Stringify.value(manager.pi_binary, .{}, &output.writer);
        try output.writer.writeAll(",\"guidance\":\"Install Pi and configure LOCAL_STUDIO_HEAD_URL plus LOCAL_STUDIO_HEAD_API_KEY on an enrolled harness node.\"}],\"diagnostics\":[]}");
        return output.toOwnedSlice();
    }
    pub fn piIsAvailable(manager: *Manager) bool {
        return manager.piAvailable() and manager.model_route.available();
    }
    pub fn sessionsPayload(manager: *Manager) ![]u8 {
        try manager.mutex.lock(manager.io);
        defer manager.mutex.unlock(manager.io);
        var output: Io.Writer.Allocating = .init(manager.allocator);
        errdefer output.deinit();
        try output.writer.writeAll("{\"sessions\":[");
        var iterator = manager.sessions.iterator();
        var wrote = false;
        while (iterator.next()) |entry| {
            if (wrote) try output.writer.writeByte(',');
            try output.writer.writeAll("{\"sessionId\":");
            try std.json.Stringify.value(entry.key_ptr.*, .{}, &output.writer);
            try output.writer.writeAll(",\"status\":");
            try writeStatus(&output.writer, entry.value_ptr.*);
            try output.writer.writeByte('}');
            wrote = true;
        }
        try output.writer.writeAll("]}");
        return output.toOwnedSlice();
    }

    pub fn statusPayload(manager: *Manager, session_id: []const u8, after: u64) ![]u8 {
        try manager.mutex.lock(manager.io);
        defer manager.mutex.unlock(manager.io);
        var output: Io.Writer.Allocating = .init(manager.allocator);
        errdefer output.deinit();
        try output.writer.writeAll("{\"sessionId\":");
        try std.json.Stringify.value(session_id, .{}, &output.writer);
        const session = manager.sessions.get(session_id);
        try output.writer.writeAll(",\"status\":");
        if (session) |value| try writeStatus(&output.writer, value) else try output.writer.writeAll("null");
        try output.writer.writeAll(",\"events\":[");
        if (session) |value| try writeEvents(&output.writer, value, after);
        try output.writer.writeAll("]}");
        return output.toOwnedSlice();
    }

    pub fn turnPayload(manager: *Manager, document: []const u8) ![]u8 {
        if (manager.mode == .head) return error.RemoteHarnessRequired;
        var parsed = std.json.parseFromSlice(std.json.Value, manager.allocator, document, .{}) catch return error.InvalidTurnPayload;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidTurnPayload;
        const object = parsed.value.object;
        const session_id = optionalString(object, "sessionId") orelse "default";
        const model_id = requiredString(object, "modelId") orelse return error.ModelIdRequired;
        const message = requiredString(object, "message") orelse return error.MessageRequired;
        if (!validSessionId(session_id)) return error.InvalidSessionId;
        const mode = optionalString(object, "mode") orelse "prompt";
        if (!std.mem.eql(u8, mode, "prompt") and !std.mem.eql(u8, mode, "steer") and !std.mem.eql(u8, mode, "follow_up")) return error.InvalidTurnMode;
        if (object.get("queueAction") != null) return error.QueueMutationNotSupported;
        const cwd = optionalString(object, "cwd");
        const thinking = optionalString(object, "thinkingLevel");
        const tool_access = optionalString(object, "toolAccess") orelse "read_only";
        const session = if (std.mem.eql(u8, mode, "prompt"))
            try manager.ensureSession(session_id, model_id, cwd, thinking, tool_access)
        else
            try manager.existingActiveSession(session_id);
        const was_active = session.active;
        var command: Io.Writer.Allocating = .init(manager.allocator);
        defer command.deinit();
        const command_id = manager.commandId();
        const command_type = if (std.mem.eql(u8, mode, "follow_up")) "follow_up" else mode;
        try command.writer.writeAll("{\"id\":");
        try std.json.Stringify.value(command_id[0..], .{}, &command.writer);
        try command.writer.writeAll(",\"type\":");
        try std.json.Stringify.value(command_type, .{}, &command.writer);
        try command.writer.writeAll(",\"message\":");
        try std.json.Stringify.value(message, .{}, &command.writer);
        if (object.get("images")) |images| if (images == .array and images.array.items.len > 0) {
            try command.writer.writeAll(",\"images\":");
            try std.json.Stringify.value(images, .{}, &command.writer);
        };
        if (optionalString(object, "streamingBehavior")) |behavior| {
            try command.writer.writeAll(",\"streamingBehavior\":");
            try std.json.Stringify.value(behavior, .{}, &command.writer);
        }
        try command.writer.writeByte('}');
        const acknowledgement = try manager.sendCommand(session, command_id[0..], command.writer.buffered());
        defer manager.allocator.free(acknowledgement);
        try manager.mutex.lock(manager.io);
        defer manager.mutex.unlock(manager.io);
        var output: Io.Writer.Allocating = .init(manager.allocator);
        errdefer output.deinit();
        try output.writer.writeAll("{\"type\":\"command\",\"outcome\":");
        try std.json.Stringify.value(if (was_active) "queued" else "accepted", .{}, &output.writer);
        try output.writer.writeAll(",\"runtimeSessionId\":");
        try std.json.Stringify.value(session.id, .{}, &output.writer);
        try output.writer.writeAll(",\"piSessionId\":");
        try std.json.Stringify.value(session.id, .{}, &output.writer);
        try output.writer.print(",\"active\":{},\"status\":", .{session.active});
        try writeStatus(&output.writer, session);
        try output.writer.writeByte('}');
        return output.toOwnedSlice();
    }

    pub fn abortPayload(manager: *Manager, document: []const u8) ![]u8 {
        const session_id = try sessionIdFromDocument(manager.allocator, document);
        defer manager.allocator.free(session_id);
        const session = try manager.existingSession(session_id);
        const command_id = manager.commandId();
        const command = try std.fmt.allocPrint(manager.allocator, "{{\"id\":\"{s}\",\"type\":\"abort\"}}", .{command_id[0..]});
        defer manager.allocator.free(command);
        const acknowledgement = try manager.sendCommand(session, command_id[0..], command);
        defer manager.allocator.free(acknowledgement);
        return manager.allocator.dupe(u8, "{\"ok\":true,\"cleared\":{\"steering\":[],\"followUp\":[]}}");
    }

    pub fn compactPayload(manager: *Manager, document: []const u8) ![]u8 {
        var parsed = std.json.parseFromSlice(std.json.Value, manager.allocator, document, .{}) catch return error.InvalidCompactPayload;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidCompactPayload;
        const session_id = optionalString(parsed.value.object, "sessionId") orelse "default";
        const session = try manager.existingSession(session_id);
        var command: Io.Writer.Allocating = .init(manager.allocator);
        defer command.deinit();
        const command_id = manager.commandId();
        try command.writer.writeAll("{\"id\":");
        try std.json.Stringify.value(command_id[0..], .{}, &command.writer);
        try command.writer.writeAll(",\"type\":\"compact\"");
        if (optionalString(parsed.value.object, "customInstructions")) |instructions| {
            try command.writer.writeAll(",\"customInstructions\":");
            try std.json.Stringify.value(instructions, .{}, &command.writer);
        }
        try command.writer.writeByte('}');
        const acknowledgement = try manager.sendCommand(session, command_id[0..], command.writer.buffered());
        defer manager.allocator.free(acknowledgement);
        try manager.mutex.lock(manager.io);
        defer manager.mutex.unlock(manager.io);
        var output: Io.Writer.Allocating = .init(manager.allocator);
        errdefer output.deinit();
        try output.writer.writeAll("{\"ok\":true,\"result\":null,\"status\":");
        try writeStatus(&output.writer, session);
        try output.writer.writeByte('}');
        return output.toOwnedSlice();
    }

    pub fn extensionUiPayload(manager: *Manager, document: []const u8) ![]u8 {
        var parsed = std.json.parseFromSlice(std.json.Value, manager.allocator, document, .{}) catch return error.InvalidExtensionUiPayload;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidExtensionUiPayload;
        const session_id = requiredString(parsed.value.object, "sessionId") orelse return error.SessionIdRequired;
        const request_id = requiredString(parsed.value.object, "requestId") orelse return error.RequestIdRequired;
        const session = try manager.existingSession(session_id);
        var command: Io.Writer.Allocating = .init(manager.allocator);
        defer command.deinit();
        try command.writer.writeAll("{\"type\":\"extension_ui_response\",\"id\":");
        try std.json.Stringify.value(request_id, .{}, &command.writer);
        for ([_][]const u8{ "value", "confirmed", "cancelled" }) |name| if (parsed.value.object.get(name)) |value| {
            try command.writer.writeByte(',');
            try std.json.Stringify.value(name, .{}, &command.writer);
            try command.writer.writeByte(':');
            try std.json.Stringify.value(value, .{}, &command.writer);
        };
        try command.writer.writeByte('}');
        try manager.send(session, command.writer.buffered());
        return manager.allocator.dupe(u8, "{\"ok\":true}");
    }

    pub fn serveEvents(manager: *Manager, session_id: []const u8, after_value: u64, request: *std.http.Server.Request) !void {
        var write_buffer: [16 * 1024]u8 = undefined;
        var body = try request.respondStreaming(&write_buffer, .{
            .respond_options = .{
                .keep_alive = false,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/event-stream; charset=utf-8" },
                    .{ .name = "Cache-Control", .value = "no-cache, no-transform" },
                    .{ .name = "X-Accel-Buffering", .value = "no" },
                },
            },
        });
        var after = after_value;
        var idle_rounds: usize = 0;
        while (true) {
            try manager.mutex.lock(manager.io);
            const session = manager.sessions.get(session_id);
            if (session == null) {
                manager.mutex.unlock(manager.io);
                return error.SessionNotFound;
            }
            var sent = false;
            for (session.?.events.items) |event| if (event.seq > after) {
                try body.writer.print("id: {d}\ndata: {{\"type\":\"pi\",\"seq\":{d},\"event\":{s}}}\n\n", .{ event.seq, event.seq, event.document });
                after = event.seq;
                sent = true;
            };
            const active = session.?.active;
            const status = try statusDocument(manager.allocator, session.?);
            manager.mutex.unlock(manager.io);
            defer manager.allocator.free(status);
            if (sent) {
                try body.writer.flush();
                try body.flush();
                idle_rounds = 0;
            } else idle_rounds += 1;
            if (!active and idle_rounds >= 2) {
                try body.writer.print("data: {{\"type\":\"status\",\"phase\":\"idle\",\"session\":{s}}}\n\n", .{status});
                try body.end();
                return;
            }
            if (idle_rounds % 80 == 0) {
                try body.writer.print("data: {{\"type\":\"status\",\"phase\":\"running\",\"session\":{s}}}\n\n", .{status});
                try body.writer.flush();
                try body.flush();
            }
            try manager.io.sleep(.fromMilliseconds(250), .awake);
        }
    }

    fn ensureSession(manager: *Manager, session_id: []const u8, model_id: []const u8, cwd_value: ?[]const u8, thinking: ?[]const u8, tool_access: []const u8) !*Session {
        try manager.mutex.lock(manager.io);
        defer manager.mutex.unlock(manager.io);
        if (manager.sessions.get(session_id)) |session| {
            if (!session.running) return error.HarnessExited;
            if (!std.mem.eql(u8, session.model_id, model_id)) return error.ModelChangeRequiresNewSession;
            return session;
        }
        const cwd = cwd_value orelse try Io.Dir.cwd().realPathFileAlloc(manager.io, ".", manager.allocator);
        defer if (cwd_value == null) manager.allocator.free(cwd);
        if (!std.fs.path.isAbsolute(cwd)) return error.CwdMustBeAbsolute;
        const session_dir = try std.fs.path.join(manager.allocator, &.{ manager.data_dir, "harness", "pi", "sessions" });
        errdefer manager.allocator.free(session_dir);
        _ = try Io.Dir.cwd().createDirPathStatus(manager.io, session_dir, @enumFromInt(0o700));
        const log_filename = try std.fmt.allocPrint(manager.allocator, "{s}.log", .{session_id});
        defer manager.allocator.free(log_filename);
        const log_path = try std.fs.path.join(manager.allocator, &.{ manager.data_dir, "harness", "pi", "logs", log_filename });
        defer manager.allocator.free(log_path);
        const log_directory = std.fs.path.dirname(log_path) orelse manager.data_dir;
        _ = try Io.Dir.cwd().createDirPathStatus(manager.io, log_directory, @enumFromInt(0o700));
        var log_file = try Io.Dir.cwd().createFile(manager.io, log_path, .{ .permissions = @enumFromInt(0o600), .truncate = false });
        defer log_file.close(manager.io);
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(manager.allocator);
        var model_route = try manager.model_route.prepare(model_id);
        defer model_route.deinit();
        try argv.appendSlice(manager.allocator, &.{ manager.pi_binary, "--mode", "rpc", "--session-dir", session_dir, "--session-id", session_id, "--model", model_route.model_name });
        if (thinking) |level| if (!std.mem.eql(u8, level, "auto")) try argv.appendSlice(manager.allocator, &.{ "--thinking", level });
        if (!std.mem.eql(u8, tool_access, "full")) try argv.appendSlice(manager.allocator, &.{ "--tools", "read,grep,find,ls" });
        var child = try std.process.spawn(manager.io, .{
            .argv = argv.items,
            .environ_map = &model_route.environment,
            .cwd = .{ .path = cwd },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .{ .file = log_file },
            .pgid = 0,
        });
        errdefer child.kill(manager.io);
        const session = try manager.allocator.create(Session);
        errdefer manager.allocator.destroy(session);
        session.* = .{
            .allocator = manager.allocator,
            .id = try manager.allocator.dupe(u8, session_id),
            .model_id = try manager.allocator.dupe(u8, model_id),
            .cwd = try manager.allocator.dupe(u8, cwd),
            .session_dir = session_dir,
            .child = child,
        };
        errdefer {
            manager.allocator.free(session.id);
            manager.allocator.free(session.model_id);
            manager.allocator.free(session.cwd);
        }
        try manager.sessions.put(manager.allocator, session.id, session);
        manager.tasks.concurrent(manager.io, readHarness, .{ manager, session }) catch |failure| {
            _ = manager.sessions.remove(session.id);
            return failure;
        };
        return session;
    }
    fn existingSession(manager: *Manager, session_id: []const u8) !*Session {
        try manager.mutex.lock(manager.io);
        defer manager.mutex.unlock(manager.io);
        return manager.sessions.get(session_id) orelse error.SessionNotFound;
    }

    fn existingActiveSession(manager: *Manager, session_id: []const u8) !*Session {
        const session = try manager.existingSession(session_id);
        if (!session.running or !session.active) return error.SessionNotActive;
        return session;
    }

    fn send(manager: *Manager, session: *Session, document: []const u8) !void {
        try manager.mutex.lock(manager.io);
        defer manager.mutex.unlock(manager.io);
        if (!session.running or session.child.stdin == null) return error.HarnessExited;
        try session.child.stdin.?.writeStreamingAll(manager.io, document);
        try session.child.stdin.?.writeStreamingAll(manager.io, "\n");
    }

    fn sendCommand(manager: *Manager, session: *Session, command_id: []const u8, document: []const u8) ![]u8 {
        try manager.send(session, document);
        var attempts: usize = 0;
        while (attempts < 500) : (attempts += 1) {
            try manager.mutex.lock(manager.io);
            if (session.responses.fetchRemove(command_id)) |entry| {
                manager.mutex.unlock(manager.io);
                manager.allocator.free(entry.key);
                const response = entry.value;
                validateAcknowledgement(manager.allocator, response) catch |failure| {
                    manager.allocator.free(response);
                    return failure;
                };
                return response;
            }
            const running = session.running;
            manager.mutex.unlock(manager.io);
            if (!running) return error.HarnessExited;
            try manager.io.sleep(.fromMilliseconds(10), .awake);
        }
        return error.HarnessCommandTimeout;
    }

    fn commandId(manager: *Manager) [32]u8 {
        var bytes: [16]u8 = undefined;
        manager.io.random(&bytes);
        return std.fmt.bytesToHex(bytes, .lower);
    }

    fn piAvailable(manager: *Manager) bool {
        const result = std.process.run(manager.allocator, manager.io, .{
            .argv = &.{ manager.pi_binary, "--version" },
            .environ_map = manager.environment,
            .stdout_limit = .limited(64 * 1024),
            .stderr_limit = .limited(64 * 1024),
            .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(3) } },
        }) catch return false;
        defer manager.allocator.free(result.stdout);
        defer manager.allocator.free(result.stderr);
        return switch (result.term) {
            .exited => |code| code == 0,
            else => false,
        };
    }

    fn handleLine(manager: *Manager, session: *Session, line_value: []const u8) !void {
        const line = std.mem.trim(u8, line_value, " \t\r");
        if (line.len == 0 or line.len > max_event_bytes) return;
        var parsed = std.json.parseFromSlice(std.json.Value, manager.allocator, line, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const event_type = optionalString(parsed.value.object, "type") orelse return;
        if (std.mem.eql(u8, event_type, "response")) {
            const response_id = optionalString(parsed.value.object, "id") orelse return;
            try manager.mutex.lock(manager.io);
            defer manager.mutex.unlock(manager.io);
            if (session.responses.fetchRemove(response_id)) |previous| {
                manager.allocator.free(previous.key);
                manager.allocator.free(previous.value);
            }
            const key = try manager.allocator.dupe(u8, response_id);
            errdefer manager.allocator.free(key);
            try session.responses.put(manager.allocator, key, try manager.allocator.dupe(u8, line));
            return;
        }
        try manager.mutex.lock(manager.io);
        defer manager.mutex.unlock(manager.io);
        if (std.mem.eql(u8, event_type, "agent_start")) session.active = true;
        if (std.mem.eql(u8, event_type, "agent_settled")) session.active = false;
        session.event_seq += 1;
        var timestamp: [24]u8 = undefined;
        _ = formatTimestamp(manager.io, &timestamp);
        try session.events.append(manager.allocator, .{
            .allocator = manager.allocator,
            .seq = session.event_seq,
            .document = try manager.allocator.dupe(u8, line),
            .timestamp = timestamp,
        });
        if (session.events.items.len > max_events) {
            session.events.items[0].deinit();
            _ = session.events.orderedRemove(0);
        }
    }
};

fn readHarness(manager: *Manager, session: *Session) Io.Cancelable!void {
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(manager.allocator);
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const count = session.child.stdout.?.readStreaming(manager.io, &.{&chunk}) catch |failure| switch (failure) {
            error.EndOfStream => break,
            error.Canceled => return error.Canceled,
            else => break,
        };
        if (count == 0) break;
        pending.appendSlice(manager.allocator, chunk[0..count]) catch break;
        if (pending.items.len > max_event_bytes) {
            pending.clearRetainingCapacity();
            continue;
        }
        var consumed: usize = 0;
        while (std.mem.indexOfScalarPos(u8, pending.items, consumed, '\n')) |newline| {
            manager.handleLine(session, pending.items[consumed..newline]) catch {};
            consumed = newline + 1;
        }
        if (consumed > 0) {
            const remaining = pending.items[consumed..];
            std.mem.copyForwards(u8, pending.items[0..remaining.len], remaining);
            pending.items.len = remaining.len;
        }
    }
    if (pending.items.len > 0) manager.handleLine(session, pending.items) catch {};
    try manager.mutex.lock(manager.io);
    defer manager.mutex.unlock(manager.io);
    const term = if (session.child.id != null) session.child.wait(manager.io) catch null else null;
    session.running = false;
    session.active = false;
    if (term) |value| switch (value) {
        .exited => |code| {
            if (code != 0) session.last_error = std.fmt.allocPrint(manager.allocator, "Pi exited with code {d}", .{code}) catch null;
        },
        .signal => |signal| {
            session.last_error = std.fmt.allocPrint(manager.allocator, "Pi exited on signal {d}", .{@intFromEnum(signal)}) catch null;
        },
        else => {
            session.last_error = manager.allocator.dupe(u8, "Pi exited unexpectedly") catch null;
        },
    };
}

fn writeStatus(writer: *Io.Writer, session: *const Session) !void {
    try writer.print("{{\"running\":{},\"active\":{},\"modelId\":", .{ session.running, session.active });
    try std.json.Stringify.value(session.model_id, .{}, writer);
    try writer.writeAll(",\"cwd\":");
    try std.json.Stringify.value(session.cwd, .{}, writer);
    try writer.writeAll(",\"piSessionId\":");
    try std.json.Stringify.value(session.id, .{}, writer);
    try writer.writeAll(",\"agentDir\":");
    try std.json.Stringify.value(session.session_dir, .{}, writer);
    try writer.print(",\"eventSeq\":{d},\"lastError\":", .{session.event_seq});
    if (session.last_error) |value| try std.json.Stringify.value(value, .{}, writer) else try writer.writeAll("null");
    try writer.writeAll(",\"contextUsage\":null}");
}

fn statusDocument(allocator: std.mem.Allocator, session: *const Session) ![]u8 {
    var output: Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try writeStatus(&output.writer, session);
    return output.toOwnedSlice();
}

fn writeEvents(writer: *Io.Writer, session: *const Session, after: u64) !void {
    var wrote = false;
    for (session.events.items) |event| if (event.seq > after) {
        if (wrote) try writer.writeByte(',');
        try writer.print("{{\"seq\":{d},\"event\":{s},\"timestamp\":", .{ event.seq, event.document });
        try std.json.Stringify.value(event.timestamp[0..], .{}, writer);
        try writer.writeByte('}');
        wrote = true;
    };
}

fn sessionIdFromDocument(allocator: std.mem.Allocator, document: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, document, .{}) catch return error.InvalidSessionPayload;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidSessionPayload;
    const id = optionalString(parsed.value.object, "sessionId") orelse "default";
    if (!validSessionId(id)) return error.InvalidSessionId;
    return allocator.dupe(u8, id);
}

fn validateAcknowledgement(allocator: std.mem.Allocator, document: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, document, .{}) catch return error.InvalidHarnessResponse;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidHarnessResponse;
    const success = parsed.value.object.get("success") orelse return error.InvalidHarnessResponse;
    if (success != .bool) return error.InvalidHarnessResponse;
    if (!success.bool) return error.HarnessCommandRejected;
}

fn optionalString(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    if (value != .string) return null;
    const trimmed = std.mem.trim(u8, value.string, " \t\r\n");
    return if (trimmed.len > 0) trimmed else null;
}

fn requiredString(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    return optionalString(object, name);
}

fn validSessionId(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    for (value) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-' and byte != '.' and byte != ':') return false;
    return true;
}

fn formatTimestamp(io: Io, buffer: *[24]u8) []const u8 {
    const seconds = Io.Clock.real.now(io).toSeconds();
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(seconds, 0)) };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.000Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    }) catch unreachable;
}
