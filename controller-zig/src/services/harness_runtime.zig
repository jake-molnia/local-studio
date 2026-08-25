const std = @import("std");
const config_module = @import("../config.zig");
const harness_catalog = @import("harness_catalog.zig");
const harness_events = @import("harness_events.zig");
const pi_model_route = @import("pi_model_route.zig");
const harness_session_id = @import("harness_session_id.zig");

const Io = std.Io;
const max_event_bytes = 16 * 1024 * 1024;
const max_events = 4000;
const Harness = enum {
    pi,
    chat,
    fx,
    codex,

    fn name(harness: Harness) []const u8 {
        return @tagName(harness);
    }
};
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
    harness: Harness,
    id: []u8,
    native_id: []u8,
    harness_version: ?[]u8,
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
        session.allocator.free(session.native_id);
        if (session.harness_version) |value| session.allocator.free(value);
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
    data_dir: []u8,
    controller_origin: []u8,
    controller_api_key: ?[]u8,
    pi: harness_catalog.Installation,
    codex: harness_catalog.Installation,
    fx: harness_catalog.Installation,
    model_route: pi_model_route.Config,
    mutex: Io.Mutex = .init,
    tasks: Io.Group = .init,
    sessions: std.StringHashMapUnmanaged(*Session) = .empty,
    pub fn init(allocator: std.mem.Allocator, io: Io, configuration: *const config_module.Config) !Manager {
        var model_route = try pi_model_route.Config.init(allocator, io, configuration);
        errdefer model_route.deinit();
        var pi = try harness_catalog.discoverPi(allocator, io, configuration);
        errdefer pi.deinit();
        var codex = try harness_catalog.discoverCodex(allocator, io, configuration);
        errdefer codex.deinit();
        var fx = try harness_catalog.discoverFx(allocator, io, configuration);
        errdefer fx.deinit();
        const data_dir = try allocator.dupe(u8, configuration.data_dir);
        errdefer allocator.free(data_dir);
        const controller_origin = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{configuration.port});
        errdefer allocator.free(controller_origin);
        const controller_api_key = if (configuration.api_key) |value| try allocator.dupe(u8, value) else null;
        errdefer if (controller_api_key) |value| allocator.free(value);
        return .{
            .allocator = allocator,
            .io = io,
            .mode = configuration.mode,
            .data_dir = data_dir,
            .controller_origin = controller_origin,
            .controller_api_key = controller_api_key,
            .pi = pi,
            .codex = codex,
            .fx = fx,
            .model_route = model_route,
        };
    }
    pub fn deinit(manager: *Manager) void {
        manager.tasks.cancel(manager.io);
        var iterator = manager.sessions.valueIterator();
        while (iterator.next()) |session| session.*.deinit(manager.io);
        manager.sessions.deinit(manager.allocator);
        manager.allocator.free(manager.data_dir);
        manager.allocator.free(manager.controller_origin);
        if (manager.controller_api_key) |value| manager.allocator.free(value);
        manager.pi.deinit();
        manager.codex.deinit();
        manager.fx.deinit();
        manager.model_route.deinit();
        manager.* = undefined;
    }
    pub fn setupPayload(manager: *Manager) ![]u8 {
        const available = manager.piIsAvailable();
        var output: Io.Writer.Allocating = .init(manager.allocator);
        errdefer output.deinit();
        try output.writer.writeAll("{\"checks\":[{\"id\":\"pi-rpc\",\"label\":\"Pi RPC harness\",\"ok\":");
        try output.writer.print("{},\"value\":", .{available});
        try std.json.Stringify.value(manager.pi.executable, .{}, &output.writer);
        try output.writer.writeAll(",\"guidance\":\"Install Pi and configure LOCAL_STUDIO_HEAD_URL plus LOCAL_STUDIO_HEAD_API_KEY on an enrolled harness node.\"}],\"diagnostics\":[]}");
        return output.toOwnedSlice();
    }
    pub fn piIsAvailable(manager: *Manager) bool {
        return manager.pi.available() and manager.model_route.available();
    }
    pub fn piVersion(manager: *const Manager) ?[]const u8 {
        return manager.pi.version;
    }
    pub fn codexIsAvailable(manager: *const Manager) bool {
        return manager.codex.available();
    }
    pub fn codexVersion(manager: *const Manager) ?[]const u8 {
        return manager.codex.version;
    }
    pub fn codexSource(manager: *const Manager) []const u8 {
        return manager.codex.source;
    }
    pub fn fxIsAvailable(manager: *const Manager) bool {
        return manager.fx.available();
    }
    pub fn fxVersion(manager: *const Manager) ?[]const u8 {
        return manager.fx.version;
    }
    pub fn fxSource(manager: *const Manager) []const u8 {
        return manager.fx.source;
    }
    pub fn piSource(manager: *const Manager) []const u8 {
        return manager.pi.source;
    }
    pub fn catalogPayload(manager: *Manager) ![]u8 {
        var output: Io.Writer.Allocating = .init(manager.allocator);
        errdefer output.deinit();
        try harness_catalog.writeCatalog(&output.writer, &manager.pi, &manager.codex, &manager.fx);
        return output.toOwnedSlice();
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

    pub fn transcriptPayload(manager: *Manager, session_id: []const u8, native_session_id: ?[]const u8, since: ?[]const u8) ![]u8 {
        if (!harness_session_id.validRuntime(session_id)) return error.InvalidSessionId;
        if (since) |entry_id| if (!validEntryId(entry_id)) return error.InvalidTranscriptCursor;
        try manager.mutex.lock(manager.io);
        const active_session = manager.sessions.get(session_id);
        manager.mutex.unlock(manager.io);
        if (active_session == null) {
            const native_id = native_session_id orelse return error.NativeSessionIdRequired;
            if (!harness_session_id.validNative(native_id)) return error.InvalidNativeSessionId;
            const acknowledgement = try manager.readPersistedTranscript(native_id, since);
            defer manager.allocator.free(acknowledgement);
            return manager.transcriptEnvelope(session_id, native_id, acknowledgement);
        }
        const session = active_session.?;
        if (session.harness != .pi) return manager.eventTranscriptEnvelope(session_id, session);
        var command: Io.Writer.Allocating = .init(manager.allocator);
        defer command.deinit();
        const command_id = manager.commandId();
        try command.writer.writeAll("{\"id\":");
        try std.json.Stringify.value(command_id[0..], .{}, &command.writer);
        try command.writer.writeAll(",\"type\":\"get_entries\"");
        if (since) |entry_id| {
            try command.writer.writeAll(",\"since\":");
            try std.json.Stringify.value(entry_id, .{}, &command.writer);
        }
        try command.writer.writeByte('}');
        const acknowledgement = try manager.sendCommand(session, command_id[0..], command.writer.buffered());
        defer manager.allocator.free(acknowledgement);
        return manager.transcriptEnvelope(session_id, session.native_id, acknowledgement);
    }

    fn eventTranscriptEnvelope(manager: *Manager, session_id: []const u8, session: *Session) ![]u8 {
        try manager.mutex.lock(manager.io);
        defer manager.mutex.unlock(manager.io);
        var output: Io.Writer.Allocating = .init(manager.allocator);
        errdefer output.deinit();
        try output.writer.writeAll("{\"sessionId\":");
        try std.json.Stringify.value(session_id, .{}, &output.writer);
        try output.writer.writeAll(",\"harness\":");
        try std.json.Stringify.value(session.harness.name(), .{}, &output.writer);
        try output.writer.writeAll(",\"nativeSessionId\":");
        try std.json.Stringify.value(session.native_id, .{}, &output.writer);
        try output.writer.writeAll(",\"entries\":[");
        for (session.events.items, 0..) |event, index| {
            if (index > 0) try output.writer.writeByte(',');
            if (session.harness == .codex)
                try harness_events.writeCanonical(manager.allocator, &output.writer, "codex", event.document)
            else
                try output.writer.writeAll(event.document);
        }
        try output.writer.writeAll("],\"leafId\":");
        if (session.events.items.len > 0) try output.writer.print("\"{d}\"", .{session.event_seq}) else try output.writer.writeAll("null");
        try output.writer.writeByte('}');
        return output.toOwnedSlice();
    }

    fn transcriptEnvelope(manager: *Manager, session_id: []const u8, native_id: []const u8, acknowledgement: []const u8) ![]u8 {
        var parsed = std.json.parseFromSlice(std.json.Value, manager.allocator, acknowledgement, .{}) catch return error.InvalidHarnessResponse;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidHarnessResponse;
        const data = parsed.value.object.get("data") orelse return error.InvalidHarnessResponse;
        if (data != .object) return error.InvalidHarnessResponse;
        const entries = data.object.get("entries") orelse return error.InvalidHarnessResponse;
        if (entries != .array) return error.InvalidHarnessResponse;
        const leaf_id = data.object.get("leafId") orelse .null;
        if (leaf_id != .null and leaf_id != .string) return error.InvalidHarnessResponse;
        var output: Io.Writer.Allocating = .init(manager.allocator);
        errdefer output.deinit();
        try output.writer.writeAll("{\"sessionId\":");
        try std.json.Stringify.value(session_id, .{}, &output.writer);
        try output.writer.writeAll(",\"harness\":\"pi\",\"nativeSessionId\":");
        try std.json.Stringify.value(native_id, .{}, &output.writer);
        try output.writer.writeAll(",\"entries\":");
        try std.json.Stringify.value(entries, .{}, &output.writer);
        try output.writer.writeAll(",\"leafId\":");
        try std.json.Stringify.value(leaf_id, .{}, &output.writer);
        try output.writer.writeByte('}');
        return output.toOwnedSlice();
    }

    fn readPersistedTranscript(manager: *Manager, native_id: []const u8, since: ?[]const u8) ![]u8 {
        if (!manager.pi.available()) return error.HarnessUnavailable;
        const session_path = try manager.nativeSessionPath(native_id);
        defer manager.allocator.free(session_path);
        var environment = try manager.model_route.environment.clone(manager.allocator);
        defer environment.deinit();
        try environment.put("PI_CODING_AGENT_DIR", manager.model_route.agent_dir);
        var child = try std.process.spawn(manager.io, .{
            .argv = &.{ manager.pi.executable, "--mode", "rpc", "--session", session_path },
            .environ_map = &environment,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
            .pgid = 0,
        });
        defer child.kill(manager.io);
        const command_id = manager.commandId();
        var command: Io.Writer.Allocating = .init(manager.allocator);
        defer command.deinit();
        try command.writer.writeAll("{\"id\":");
        try std.json.Stringify.value(command_id[0..], .{}, &command.writer);
        try command.writer.writeAll(",\"type\":\"get_entries\"");
        if (since) |entry_id| {
            try command.writer.writeAll(",\"since\":");
            try std.json.Stringify.value(entry_id, .{}, &command.writer);
        }
        try command.writer.writeAll("}\n");
        try child.stdin.?.writeStreamingAll(manager.io, command.writer.buffered());
        child.stdin.?.close(manager.io);
        child.stdin = null;
        var received: std.ArrayList(u8) = .empty;
        defer received.deinit(manager.allocator);
        var chunk: [64 * 1024]u8 = undefined;
        while (true) {
            const count = child.stdout.?.readStreaming(manager.io, &.{&chunk}) catch |failure| switch (failure) {
                error.EndOfStream => break,
                else => return failure,
            };
            if (count == 0) break;
            if (received.items.len + count > max_event_bytes) return error.TranscriptTooLarge;
            try received.appendSlice(manager.allocator, chunk[0..count]);
        }
        var lines = std.mem.splitScalar(u8, received.items, '\n');
        while (lines.next()) |line_value| {
            const line = std.mem.trim(u8, line_value, " \t\r");
            var parsed = std.json.parseFromSlice(std.json.Value, manager.allocator, line, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .object) continue;
            const response_id = optionalString(parsed.value.object, "id") orelse continue;
            if (!std.mem.eql(u8, response_id, command_id[0..])) continue;
            try validateAcknowledgement(manager.allocator, line);
            return manager.allocator.dupe(u8, line);
        }
        return error.InvalidHarnessResponse;
    }

    fn nativeSessionPath(manager: *Manager, native_id: []const u8) ![]u8 {
        const session_dir = try std.fs.path.join(manager.allocator, &.{ manager.data_dir, "harness", "pi", "sessions" });
        defer manager.allocator.free(session_dir);
        var directory = Io.Dir.cwd().openDir(manager.io, session_dir, .{ .iterate = true }) catch return error.SessionNotFound;
        defer directory.close(manager.io);
        const suffix = try std.fmt.allocPrint(manager.allocator, "_{s}.jsonl", .{native_id});
        defer manager.allocator.free(suffix);
        const exact = try std.fmt.allocPrint(manager.allocator, "{s}.jsonl", .{native_id});
        defer manager.allocator.free(exact);
        var selected: ?[]u8 = null;
        defer if (selected) |value| manager.allocator.free(value);
        var iterator = directory.iterateAssumeFirstIteration();
        while (try iterator.next(manager.io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.eql(u8, entry.name, exact) and !std.mem.endsWith(u8, entry.name, suffix)) continue;
            if (selected == null or std.mem.order(u8, entry.name, selected.?) == .gt) {
                if (selected) |value| manager.allocator.free(value);
                selected = try manager.allocator.dupe(u8, entry.name);
            }
        }
        return std.fs.path.join(manager.allocator, &.{ session_dir, selected orelse return error.SessionNotFound });
    }

    pub fn turnPayload(manager: *Manager, document: []const u8) ![]u8 {
        return manager.turnPayloadAt(document, 0, null);
    }

    pub fn turnPayloadAt(manager: *Manager, document: []const u8, initial_event_seq: u64, native_session_id: ?[]const u8) ![]u8 {
        if (manager.mode == .head) return error.RemoteHarnessRequired;
        var parsed = std.json.parseFromSlice(std.json.Value, manager.allocator, document, .{}) catch return error.InvalidTurnPayload;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidTurnPayload;
        const object = parsed.value.object;
        const harness = optionalString(object, "harness") orelse "pi";
        const harness_kind: Harness = if (std.mem.eql(u8, harness, "pi")) .pi else if (std.mem.eql(u8, harness, "chat")) .chat else if (std.mem.eql(u8, harness, "fx")) .fx else if (std.mem.eql(u8, harness, "codex")) .codex else return error.HarnessDriverUnavailable;
        if (harness_kind == .pi and !manager.piIsAvailable()) return error.HarnessUnavailable;
        if ((harness_kind == .chat or harness_kind == .fx) and !manager.model_route.available()) return error.HarnessUnavailable;
        if (harness_kind == .fx and !manager.fx.available()) return error.HarnessUnavailable;
        if (harness_kind == .codex and !manager.codexIsAvailable()) return error.HarnessUnavailable;
        const session_id = optionalString(object, "sessionId") orelse "default";
        const model_id = optionalString(object, "modelRouteId") orelse requiredString(object, "modelId") orelse return error.ModelIdRequired;
        const message = requiredString(object, "message") orelse return error.MessageRequired;
        if (!harness_session_id.validRuntime(session_id)) return error.InvalidSessionId;
        const mode = optionalString(object, "mode") orelse "prompt";
        if (!std.mem.eql(u8, mode, "prompt") and !std.mem.eql(u8, mode, "steer") and !std.mem.eql(u8, mode, "follow_up")) return error.InvalidTurnMode;
        if (harness_kind != .pi and !std.mem.eql(u8, mode, "prompt")) return error.QueueMutationNotSupported;
        if (object.get("queueAction") != null) return error.QueueMutationNotSupported;
        const cwd = optionalString(object, "cwd");
        const thinking = optionalString(object, "thinkingLevel");
        const browser_tool_enabled = optionalBool(object, "browserToolEnabled") orelse false;
        const tool_access = optionalString(object, "toolAccess") orelse "read_only";
        const requested_native_id = optionalString(object, "nativeSessionId") orelse optionalString(object, "piSessionId") orelse native_session_id;
        const session = if (std.mem.eql(u8, mode, "prompt"))
            if (harness_kind == .chat)
                try manager.ensureChatSession(session_id, requested_native_id, model_id, initial_event_seq)
            else if (harness_kind == .fx)
                try manager.ensureAcpSession(harness_kind, session_id, requested_native_id, model_id, cwd, initial_event_seq)
            else if (harness_kind == .codex)
                try manager.ensureCodexSession(session_id, requested_native_id, model_id, cwd, message, thinking, tool_access, initial_event_seq)
            else
                try manager.ensureSession(session_id, requested_native_id, model_id, cwd, thinking, tool_access)
        else
            try manager.existingActiveSession(session_id);
        if (session.harness != harness_kind) return error.SessionHarnessMismatch;
        if ((harness_kind == .chat or harness_kind == .fx) and session.active) return error.QueueMutationNotSupported;
        const was_active = session.active;
        if (harness_kind == .chat or harness_kind == .fx) {
            if (harness_kind == .chat)
                try manager.sendChatPrompt(session, message, thinking, browser_tool_enabled)
            else
                try manager.sendAcpPrompt(session, message);
            session.active = true;
        }
        if (harness_kind == .chat or harness_kind == .fx) return manager.turnResponse(session, was_active);
        if (harness_kind == .codex) {
            return manager.turnResponse(session, false);
        }
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
        try std.json.Stringify.value(session.native_id, .{}, &output.writer);
        try output.writer.writeAll(",\"harness\":\"pi\",\"harnessVersion\":");
        if (manager.pi.version) |value| try std.json.Stringify.value(value, .{}, &output.writer) else try output.writer.writeAll("null");
        try output.writer.writeAll(",\"nativeSessionId\":");
        try std.json.Stringify.value(session.native_id, .{}, &output.writer);
        try output.writer.print(",\"active\":{},\"status\":", .{session.active});
        try writeStatus(&output.writer, session);
        try output.writer.writeByte('}');
        return output.toOwnedSlice();
    }

    fn turnResponse(manager: *Manager, session: *Session, was_active: bool) ![]u8 {
        var output: Io.Writer.Allocating = .init(manager.allocator);
        errdefer output.deinit();
        try output.writer.writeAll("{\"type\":\"command\",\"outcome\":");
        try std.json.Stringify.value(if (was_active) "queued" else "accepted", .{}, &output.writer);
        try output.writer.writeAll(",\"runtimeSessionId\":");
        try std.json.Stringify.value(session.id, .{}, &output.writer);
        try output.writer.writeAll(",\"nativeSessionId\":");
        try std.json.Stringify.value(session.native_id, .{}, &output.writer);
        try output.writer.writeAll(",\"harness\":");
        try std.json.Stringify.value(session.harness.name(), .{}, &output.writer);
        try output.writer.writeAll(",\"harnessVersion\":");
        if (session.harness_version) |value| try std.json.Stringify.value(value, .{}, &output.writer) else try output.writer.writeAll("null");
        try output.writer.print(",\"active\":{},\"status\":", .{session.active});
        try writeStatus(&output.writer, session);
        try output.writer.writeByte('}');
        return output.toOwnedSlice();
    }

    pub fn abortPayload(manager: *Manager, document: []const u8) ![]u8 {
        const session_id = try sessionIdFromDocument(manager.allocator, document);
        defer manager.allocator.free(session_id);
        const session = try manager.existingSession(session_id);
        if (session.harness == .fx) {
            try manager.send(session, "{\"jsonrpc\":\"2.0\",\"method\":\"session/cancel\",\"params\":{}}");
            return manager.allocator.dupe(u8, "{\"ok\":true,\"cleared\":{\"steering\":[],\"followUp\":[]}}");
        }
        if (session.harness == .chat or session.harness == .codex) {
            try manager.mutex.lock(manager.io);
            defer manager.mutex.unlock(manager.io);
            if (session.child.id != null) session.child.kill(manager.io);
            return manager.allocator.dupe(u8, "{\"ok\":true,\"cleared\":{\"steering\":[],\"followUp\":[]}}");
        }
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
        if (session.harness != .pi) return error.QueueMutationNotSupported;
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
                try body.writer.print("id: {d}\ndata: ", .{event.seq});
                try harness_events.writeStreamEnvelope(manager.allocator, &body.writer, session.?.harness.name(), event.seq, event.document);
                try body.writer.writeAll("\n\n");
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

    fn ensureSession(manager: *Manager, session_id: []const u8, native_value: ?[]const u8, model_id: []const u8, cwd_value: ?[]const u8, thinking: ?[]const u8, tool_access: []const u8) !*Session {
        try manager.mutex.lock(manager.io);
        defer manager.mutex.unlock(manager.io);
        if (manager.sessions.get(session_id)) |session| {
            if (!session.running) return error.HarnessExited;
            if (!std.mem.eql(u8, session.model_id, model_id)) return error.ModelChangeRequiresNewSession;
            return session;
        }
        const resolved_cwd = if (cwd_value == null) try Io.Dir.cwd().realPathFileAlloc(manager.io, ".", manager.allocator) else null;
        defer if (resolved_cwd) |value| manager.allocator.free(value);
        const cwd = cwd_value orelse resolved_cwd.?;
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
        try model_route.environment.put("LOCAL_STUDIO_MODEL_ID", model_id);
        try manager.addMcpBridgeEnvironment(&model_route.environment, model_id, session_id);
        const native_id = try harness_session_id.resolve(manager.allocator, session_id, native_value);
        errdefer manager.allocator.free(native_id);
        try argv.appendSlice(manager.allocator, &.{ manager.pi.executable, "--mode", "rpc", "--session-dir", session_dir, "--session-id", native_id, "--model", model_route.model_name });
        const connector_extension = try manager.piConnectorExtension();
        defer if (connector_extension) |value| manager.allocator.free(value);
        if (connector_extension) |value| try argv.appendSlice(manager.allocator, &.{ "--extension", value });
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
            .harness = .pi,
            .id = try manager.allocator.dupe(u8, session_id),
            .native_id = native_id,
            .harness_version = if (manager.pi.version) |value| try manager.allocator.dupe(u8, value) else null,
            .model_id = try manager.allocator.dupe(u8, model_id),
            .cwd = try manager.allocator.dupe(u8, cwd),
            .session_dir = session_dir,
            .child = child,
        };
        errdefer {
            manager.allocator.free(session.id);
            if (session.harness_version) |value| manager.allocator.free(value);
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

    fn ensureCodexSession(manager: *Manager, session_id: []const u8, native_session_id: ?[]const u8, model_id: []const u8, cwd_value: ?[]const u8, message: []const u8, thinking: ?[]const u8, tool_access: []const u8, initial_event_seq: u64) !*Session {
        try manager.mutex.lock(manager.io);
        defer manager.mutex.unlock(manager.io);
        if (manager.sessions.get(session_id)) |session| {
            if (session.harness != .codex) return error.SessionHarnessMismatch;
            if (session.running or session.active) return error.QueueMutationNotSupported;
            if (!std.mem.eql(u8, session.model_id, model_id)) return error.ModelChangeRequiresNewSession;
            if (native_session_id == null and session.last_error != null) {
                manager.allocator.free(session.native_id);
                session.native_id = try manager.allocator.dupe(u8, "");
            }
            session.child = try manager.spawnCodex(session.id, session.native_id, session.model_id, session.cwd, session.session_dir, message, thinking, tool_access);
            session.running = true;
            session.active = true;
            if (session.last_error) |value| manager.allocator.free(value);
            session.last_error = null;
            manager.tasks.concurrent(manager.io, readHarness, .{ manager, session }) catch |failure| {
                session.child.kill(manager.io);
                session.running = false;
                session.active = false;
                return failure;
            };
            return session;
        }
        const resolved_cwd = if (cwd_value == null) try Io.Dir.cwd().realPathFileAlloc(manager.io, ".", manager.allocator) else null;
        defer if (resolved_cwd) |value| manager.allocator.free(value);
        const cwd = cwd_value orelse resolved_cwd.?;
        if (!std.fs.path.isAbsolute(cwd)) return error.CwdMustBeAbsolute;
        const session_dir = try std.fs.path.join(manager.allocator, &.{ manager.data_dir, "harness", "codex" });
        errdefer manager.allocator.free(session_dir);
        _ = try Io.Dir.cwd().createDirPathStatus(manager.io, session_dir, @enumFromInt(0o700));
        const native_id = try manager.allocator.dupe(u8, native_session_id orelse "");
        errdefer manager.allocator.free(native_id);
        var child = try manager.spawnCodex(session_id, native_id, model_id, cwd, session_dir, message, thinking, tool_access);
        errdefer child.kill(manager.io);
        const session = try manager.allocator.create(Session);
        errdefer manager.allocator.destroy(session);
        session.* = .{
            .allocator = manager.allocator,
            .harness = .codex,
            .id = try manager.allocator.dupe(u8, session_id),
            .native_id = native_id,
            .harness_version = if (manager.codex.version) |value| try manager.allocator.dupe(u8, value) else null,
            .model_id = try manager.allocator.dupe(u8, model_id),
            .cwd = try manager.allocator.dupe(u8, cwd),
            .session_dir = session_dir,
            .child = child,
            .active = true,
            .event_seq = initial_event_seq,
        };
        errdefer {
            manager.allocator.free(session.id);
            if (session.harness_version) |value| manager.allocator.free(value);
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

    fn spawnCodex(manager: *Manager, session_id: []const u8, native_id: []const u8, model_id: []const u8, cwd: []const u8, session_dir: []const u8, message: []const u8, thinking: ?[]const u8, tool_access: []const u8) !std.process.Child {
        const logs_dir = try std.fs.path.join(manager.allocator, &.{ session_dir, "logs" });
        defer manager.allocator.free(logs_dir);
        _ = try Io.Dir.cwd().createDirPathStatus(manager.io, logs_dir, @enumFromInt(0o700));
        const log_filename = try std.fmt.allocPrint(manager.allocator, "{s}.log", .{session_id});
        defer manager.allocator.free(log_filename);
        const log_path = try std.fs.path.join(manager.allocator, &.{ logs_dir, log_filename });
        defer manager.allocator.free(log_path);
        var log_file = try Io.Dir.cwd().createFile(manager.io, log_path, .{ .permissions = @enumFromInt(0o600), .truncate = false });
        defer log_file.close(manager.io);
        var model_route = try manager.model_route.prepare(model_id);
        defer model_route.deinit();
        const sandbox = if (std.mem.eql(u8, tool_access, "full")) "workspace-write" else "read-only";
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(manager.allocator);
        try manager.addMcpBridgeEnvironment(&model_route.environment, model_id, session_id);
        const controller_executable = try std.process.executablePathAlloc(manager.io, manager.allocator);
        defer manager.allocator.free(controller_executable);
        const command_config = try configAssignment(manager.allocator, "mcp_servers.local-studio.command", controller_executable);
        defer manager.allocator.free(command_config);
        const provider_url_config = try configAssignment(manager.allocator, "model_providers.local_studio.base_url", model_route.base_url);
        defer manager.allocator.free(provider_url_config);
        const args_config = "mcp_servers.local-studio.args=[\"mcp-bridge\"]";
        const env_config = "mcp_servers.local-studio.env_vars=[\"LOCAL_STUDIO_MCP_BRIDGE_URL\",\"LOCAL_STUDIO_MCP_BRIDGE_MODEL\",\"LOCAL_STUDIO_MCP_BRIDGE_SESSION\",\"LOCAL_STUDIO_MCP_BRIDGE_KEY\"]";
        if (native_id.len == 0)
            try argv.appendSlice(manager.allocator, &.{ manager.codex.executable, "exec", "--json", "--color", "never", "--skip-git-repo-check", "--sandbox", sandbox, "-m", model_id })
        else
            try argv.appendSlice(manager.allocator, &.{ manager.codex.executable, "exec", "resume", "--json", "--skip-git-repo-check", "-m", model_id });
        try argv.appendSlice(manager.allocator, &.{ "-c", "model_provider=\"local_studio\"", "-c", "model_providers.local_studio.name=\"Local Studio\"", "-c", provider_url_config, "-c", "model_providers.local_studio.env_key=\"LOCAL_STUDIO_HEAD_API_KEY\"", "-c", "model_providers.local_studio.wire_api=\"responses\"", "-c", "model_providers.local_studio.requires_openai_auth=false", "-c", command_config, "-c", args_config, "-c", env_config });
        const effort = if (thinking) |value| if (!std.mem.eql(u8, value, "auto") and !std.mem.eql(u8, value, "off")) try std.fmt.allocPrint(manager.allocator, "model_reasoning_effort=\"{s}\"", .{value}) else null else null;
        defer if (effort) |value| manager.allocator.free(value);
        if (effort) |value| try argv.appendSlice(manager.allocator, &.{ "-c", value });
        if (native_id.len > 0) try argv.append(manager.allocator, native_id);
        try argv.append(manager.allocator, message);
        return std.process.spawn(manager.io, .{
            .argv = argv.items,
            .environ_map = &model_route.environment,
            .cwd = .{ .path = cwd },
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .{ .file = log_file },
            .pgid = 0,
        });
    }

    fn piConnectorExtension(manager: *Manager) !?[]u8 {
        if (manager.model_route.environment.get("LOCAL_STUDIO_RESOURCES_PATH")) |resources| {
            const path = try std.fs.path.join(manager.allocator, &.{ resources, "desktop", "resources", "pi-extensions", "connectors.ts" });
            if (Io.Dir.cwd().statFile(manager.io, path, .{})) |_| return path else |_| manager.allocator.free(path);
        }
        if (manager.model_route.environment.get("PWD")) |cwd| {
            const path = try std.fs.path.join(manager.allocator, &.{ cwd, "frontend", "desktop", "resources", "pi-extensions", "connectors.ts" });
            if (Io.Dir.cwd().statFile(manager.io, path, .{})) |_| return path else |_| manager.allocator.free(path);
        }
        return null;
    }

    fn addMcpBridgeEnvironment(manager: *Manager, environment: *std.process.Environ.Map, model_id: []const u8, session_id: []const u8) !void {
        try environment.put("LOCAL_STUDIO_MCP_BRIDGE_URL", manager.controller_origin);
        try environment.put("LOCAL_STUDIO_MCP_BRIDGE_MODEL", model_id);
        try environment.put("LOCAL_STUDIO_MCP_BRIDGE_SESSION", session_id);
        try environment.put("LOCAL_STUDIO_MCP_BRIDGE_KEY", manager.controller_api_key orelse "");
    }

    fn ensureAcpSession(manager: *Manager, harness_kind: Harness, session_id: []const u8, native_session_id: ?[]const u8, model_id: []const u8, cwd_value: ?[]const u8, initial_event_seq: u64) !*Session {
        try manager.mutex.lock(manager.io);
        defer manager.mutex.unlock(manager.io);
        if (manager.sessions.get(session_id)) |session| {
            if (!session.running) return error.HarnessExited;
            if (session.harness != harness_kind) return error.SessionHarnessMismatch;
            if (!std.mem.eql(u8, session.model_id, model_id)) return error.ModelChangeRequiresNewSession;
            return session;
        }
        const session_dir = try std.fs.path.join(manager.allocator, &.{ manager.data_dir, "harness", harness_kind.name() });
        errdefer manager.allocator.free(session_dir);
        _ = try Io.Dir.cwd().createDirPathStatus(manager.io, session_dir, @enumFromInt(0o700));
        const resolved_cwd = if (cwd_value == null) try Io.Dir.cwd().realPathFileAlloc(manager.io, ".", manager.allocator) else null;
        defer if (resolved_cwd) |value| manager.allocator.free(value);
        const cwd = cwd_value orelse resolved_cwd.?;
        if (!std.fs.path.isAbsolute(cwd)) return error.CwdMustBeAbsolute;
        const log_directory = try std.fs.path.join(manager.allocator, &.{ session_dir, "logs" });
        defer manager.allocator.free(log_directory);
        _ = try Io.Dir.cwd().createDirPathStatus(manager.io, log_directory, @enumFromInt(0o700));
        const log_filename = try std.fmt.allocPrint(manager.allocator, "{s}.log", .{session_id});
        defer manager.allocator.free(log_filename);
        const log_path = try std.fs.path.join(manager.allocator, &.{ log_directory, log_filename });
        defer manager.allocator.free(log_path);
        var log_file = try Io.Dir.cwd().createFile(manager.io, log_path, .{ .permissions = @enumFromInt(0o600), .truncate = false });
        defer log_file.close(manager.io);
        const controller_executable = try std.process.executablePathAlloc(manager.io, manager.allocator);
        defer manager.allocator.free(controller_executable);
        var model_route = try manager.model_route.prepare(model_id);
        defer model_route.deinit();
        try model_route.environment.put("LOCAL_STUDIO_FX_HOME", session_dir);
        var child = try std.process.spawn(manager.io, .{
            .argv = &.{ manager.fx.executable, "acp" },
            .environ_map = &model_route.environment,
            .cwd = .{ .path = cwd },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .{ .file = log_file },
            .pgid = 0,
        });
        errdefer child.kill(manager.io);
        const initialized = try directFxRequest(manager.allocator, manager.io, &child, "initialize", "{\"jsonrpc\":\"2.0\",\"id\":\"initialize\",\"method\":\"initialize\",\"params\":{\"protocolVersion\":1,\"clientCapabilities\":{\"fs\":{\"readTextFile\":false,\"writeTextFile\":false},\"terminal\":false}}}");
        defer manager.allocator.free(initialized);
        const session_request = try acpSessionRequest(manager, "session", controller_executable, model_id, session_id, native_session_id);
        defer manager.allocator.free(session_request);
        const created = try directFxRequest(manager.allocator, manager.io, &child, "session", session_request);
        defer manager.allocator.free(created);
        const native_id = if (native_session_id) |value| resumed: {
            if (fxResponseSucceeded(manager.allocator, created)) break :resumed try manager.allocator.dupe(u8, value);
            const fallback_request = try acpSessionRequest(manager, "session-fallback", controller_executable, model_id, session_id, null);
            defer manager.allocator.free(fallback_request);
            const fallback = try directFxRequest(manager.allocator, manager.io, &child, "session-fallback", fallback_request);
            defer manager.allocator.free(fallback);
            break :resumed try fxSessionId(manager.allocator, fallback);
        } else try fxSessionId(manager.allocator, created);
        errdefer manager.allocator.free(native_id);
        const session = try manager.allocator.create(Session);
        errdefer manager.allocator.destroy(session);
        session.* = .{
            .allocator = manager.allocator,
            .harness = harness_kind,
            .id = try manager.allocator.dupe(u8, session_id),
            .native_id = native_id,
            .harness_version = if (manager.fx.version) |value| try manager.allocator.dupe(u8, value) else null,
            .model_id = try manager.allocator.dupe(u8, model_id),
            .cwd = try manager.allocator.dupe(u8, cwd),
            .session_dir = session_dir,
            .child = child,
            .event_seq = initial_event_seq,
        };
        errdefer {
            manager.allocator.free(session.id);
            if (session.harness_version) |value| manager.allocator.free(value);
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

    fn ensureChatSession(manager: *Manager, session_id: []const u8, native_session_id: ?[]const u8, model_id: []const u8, initial_event_seq: u64) !*Session {
        try manager.mutex.lock(manager.io);
        defer manager.mutex.unlock(manager.io);
        if (manager.sessions.get(session_id)) |session| {
            if (!session.running) return error.HarnessExited;
            if (session.harness != .chat) return error.SessionHarnessMismatch;
            if (!std.mem.eql(u8, session.model_id, model_id)) return error.ModelChangeRequiresNewSession;
            return session;
        }
        const session_dir = try std.fs.path.join(manager.allocator, &.{ manager.data_dir, "harness", "chat" });
        errdefer manager.allocator.free(session_dir);
        _ = try Io.Dir.cwd().createDirPathStatus(manager.io, session_dir, @enumFromInt(0o700));
        const log_directory = try std.fs.path.join(manager.allocator, &.{ session_dir, "logs" });
        defer manager.allocator.free(log_directory);
        _ = try Io.Dir.cwd().createDirPathStatus(manager.io, log_directory, @enumFromInt(0o700));
        const log_filename = try std.fmt.allocPrint(manager.allocator, "{s}.log", .{session_id});
        defer manager.allocator.free(log_filename);
        const log_path = try std.fs.path.join(manager.allocator, &.{ log_directory, log_filename });
        defer manager.allocator.free(log_path);
        var log_file = try Io.Dir.cwd().createFile(manager.io, log_path, .{ .permissions = @enumFromInt(0o600), .truncate = false });
        defer log_file.close(manager.io);
        const controller_executable = try std.process.executablePathAlloc(manager.io, manager.allocator);
        defer manager.allocator.free(controller_executable);
        const native_id = try harness_session_id.resolve(manager.allocator, session_id, native_session_id);
        errdefer manager.allocator.free(native_id);
        var model_route = try manager.model_route.prepare(model_id);
        defer model_route.deinit();
        try model_route.environment.put("LOCAL_STUDIO_FX_HOME", session_dir);
        try model_route.environment.put("LOCAL_STUDIO_CHAT_SESSION_ID", native_id);
        try model_route.environment.put("LOCAL_STUDIO_MCP_BRIDGE_URL", manager.controller_origin);
        try model_route.environment.put("LOCAL_STUDIO_MCP_BRIDGE_MODEL", model_id);
        try model_route.environment.put("LOCAL_STUDIO_MCP_BRIDGE_SESSION", session_id);
        if (manager.controller_api_key) |value| try model_route.environment.put("LOCAL_STUDIO_MCP_BRIDGE_KEY", value);
        var child = try std.process.spawn(manager.io, .{
            .argv = &.{ controller_executable, "chat-runtime" },
            .environ_map = &model_route.environment,
            .cwd = .{ .path = session_dir },
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
            .harness = .chat,
            .id = try manager.allocator.dupe(u8, session_id),
            .native_id = native_id,
            .harness_version = try manager.allocator.dupe(u8, "0.0.0-local-studio"),
            .model_id = try manager.allocator.dupe(u8, model_id),
            .cwd = try manager.allocator.dupe(u8, session_dir),
            .session_dir = session_dir,
            .child = child,
            .event_seq = initial_event_seq,
        };
        errdefer {
            manager.allocator.free(session.id);
            manager.allocator.free(session.harness_version.?);
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

    fn sendChatPrompt(manager: *Manager, session: *Session, message: []const u8, thinking: ?[]const u8, browser_tool_enabled: bool) !void {
        var document: Io.Writer.Allocating = .init(manager.allocator);
        defer document.deinit();
        try document.writer.writeAll("{\"message\":");
        try std.json.Stringify.value(message, .{}, &document.writer);
        if (thinking) |value| {
            try document.writer.writeAll(",\"thinkingLevel\":");
            try std.json.Stringify.value(value, .{}, &document.writer);
        }
        try document.writer.print(",\"browserToolEnabled\":{}", .{browser_tool_enabled});
        try document.writer.writeByte('}');
        try manager.send(session, document.writer.buffered());
    }

    fn sendAcpPrompt(manager: *Manager, session: *Session, message: []const u8) !void {
        const request_id = manager.commandId();
        var document: Io.Writer.Allocating = .init(manager.allocator);
        defer document.deinit();
        try document.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
        try std.json.Stringify.value(request_id[0..], .{}, &document.writer);
        try document.writer.writeAll(",\"method\":\"session/prompt\",\"params\":{\"sessionId\":");
        try std.json.Stringify.value(session.native_id, .{}, &document.writer);
        try document.writer.writeAll(",\"prompt\":[{\"type\":\"text\",\"text\":");
        try std.json.Stringify.value(message, .{}, &document.writer);
        try document.writer.writeAll("}]}}");
        try manager.send(session, document.writer.buffered());
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

    fn handleLine(manager: *Manager, session: *Session, line_value: []const u8) !void {
        const line = std.mem.trim(u8, line_value, " \t\r");
        if (line.len == 0 or line.len > max_event_bytes) return;
        var parsed = std.json.parseFromSlice(std.json.Value, manager.allocator, line, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        if (session.harness == .fx) return manager.handleAcpLine(session, line, parsed.value.object);
        if (session.harness == .codex) return manager.handleCodexLine(session, line, parsed.value.object);
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

    fn handleAcpLine(manager: *Manager, session: *Session, line: []const u8, object: std.json.ObjectMap) !void {
        const method = optionalString(object, "method");
        const response_id = optionalString(object, "id");
        if (method == null and response_id == null) return;
        if (method) |name| if (std.mem.eql(u8, name, "session/request_permission")) {
            const id = object.get("id") orelse return;
            var response: Io.Writer.Allocating = .init(manager.allocator);
            defer response.deinit();
            try response.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
            try std.json.Stringify.value(id, .{}, &response.writer);
            try response.writer.writeAll(",\"result\":{\"outcome\":{\"outcome\":\"selected\",\"optionId\":\"allow_once\"}}}");
            try manager.send(session, response.writer.buffered());
        };
        try manager.mutex.lock(manager.io);
        defer manager.mutex.unlock(manager.io);
        if (method == null and response_id != null) session.active = false;
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

    fn handleCodexLine(manager: *Manager, session: *Session, line: []const u8, object: std.json.ObjectMap) !void {
        const event_type = optionalString(object, "type") orelse return;
        try manager.mutex.lock(manager.io);
        defer manager.mutex.unlock(manager.io);
        if (std.mem.eql(u8, event_type, "thread.started")) if (optionalString(object, "thread_id")) |thread_id| {
            const owned = try manager.allocator.dupe(u8, thread_id);
            manager.allocator.free(session.native_id);
            session.native_id = owned;
        };
        if (std.mem.eql(u8, event_type, "turn.started")) session.active = true;
        if (std.mem.eql(u8, event_type, "turn.completed") or std.mem.eql(u8, event_type, "turn.failed")) session.active = false;
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

fn directFxRequest(allocator: std.mem.Allocator, io: Io, child: *std.process.Child, request_id: []const u8, document: []const u8) ![]u8 {
    try child.stdin.?.writeStreamingAll(io, document);
    try child.stdin.?.writeStreamingAll(io, "\n");
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(allocator);
    var chunk: [64 * 1024]u8 = undefined;
    while (pending.items.len <= max_event_bytes) {
        const count = child.stdout.?.readStreaming(io, &.{&chunk}) catch |failure| switch (failure) {
            error.EndOfStream => return error.HarnessExited,
            else => return failure,
        };
        if (count == 0) return error.HarnessExited;
        try pending.appendSlice(allocator, chunk[0..count]);
        while (std.mem.indexOfScalar(u8, pending.items, '\n')) |newline| {
            const line = std.mem.trim(u8, pending.items[0..newline], " \t\r");
            var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
                dropPrefix(&pending, newline + 1);
                continue;
            };
            const matches = parsed.value == .object and optionalString(parsed.value.object, "id") != null and std.mem.eql(u8, optionalString(parsed.value.object, "id").?, request_id);
            parsed.deinit();
            if (matches) return allocator.dupe(u8, line);
            dropPrefix(&pending, newline + 1);
        }
    }
    return error.HarnessResponseTooLarge;
}

fn acpSessionRequest(manager: *Manager, request_id: []const u8, controller_executable: []const u8, model_id: []const u8, session_id: []const u8, native_session_id: ?[]const u8) ![]u8 {
    var request: Io.Writer.Allocating = .init(manager.allocator);
    errdefer request.deinit();
    try request.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try std.json.Stringify.value(request_id, .{}, &request.writer);
    try request.writer.writeAll(",\"method\":");
    try std.json.Stringify.value(if (native_session_id == null) "session/new" else "session/load", .{}, &request.writer);
    try request.writer.writeAll(",\"params\":{");
    if (native_session_id) |value| {
        try request.writer.writeAll("\"sessionId\":");
        try std.json.Stringify.value(value, .{}, &request.writer);
        try request.writer.writeByte(',');
    }
    try request.writer.writeAll("\"mcpServers\":[{\"name\":\"local-studio\",\"command\":");
    try std.json.Stringify.value(controller_executable, .{}, &request.writer);
    try request.writer.writeAll(",\"args\":[\"mcp-bridge\"],\"env\":[{\"name\":\"LOCAL_STUDIO_MCP_BRIDGE_URL\",\"value\":");
    try std.json.Stringify.value(manager.controller_origin, .{}, &request.writer);
    try request.writer.writeAll("},{\"name\":\"LOCAL_STUDIO_MCP_BRIDGE_MODEL\",\"value\":");
    try std.json.Stringify.value(model_id, .{}, &request.writer);
    try request.writer.writeAll("},{\"name\":\"LOCAL_STUDIO_MCP_BRIDGE_SESSION\",\"value\":");
    try std.json.Stringify.value(session_id, .{}, &request.writer);
    if (manager.controller_api_key) |key| {
        try request.writer.writeAll("},{\"name\":\"LOCAL_STUDIO_MCP_BRIDGE_KEY\",\"value\":");
        try std.json.Stringify.value(key, .{}, &request.writer);
    }
    try request.writer.writeAll("}]}]}}");
    return request.toOwnedSlice();
}

fn fxResponseSucceeded(allocator: std.mem.Allocator, document: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, document, .{}) catch return false;
    defer parsed.deinit();
    return parsed.value == .object and parsed.value.object.get("error") == null and parsed.value.object.get("result") != null;
}

fn fxSessionId(allocator: std.mem.Allocator, document: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, document, .{}) catch return error.InvalidHarnessResponse;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidHarnessResponse;
    const result = parsed.value.object.get("result") orelse return error.InvalidHarnessResponse;
    if (result != .object) return error.InvalidHarnessResponse;
    return allocator.dupe(u8, requiredString(result.object, "sessionId") orelse return error.InvalidHarnessResponse);
}

fn dropPrefix(buffer: *std.ArrayList(u8), count: usize) void {
    const remaining = buffer.items[count..];
    std.mem.copyForwards(u8, buffer.items[0..remaining.len], remaining);
    buffer.items.len = remaining.len;
}

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
            if (code != 0) session.last_error = std.fmt.allocPrint(manager.allocator, "{s} exited with code {d}", .{ session.harness.name(), code }) catch null;
        },
        .signal => |signal| {
            session.last_error = std.fmt.allocPrint(manager.allocator, "{s} exited on signal {d}", .{ session.harness.name(), @intFromEnum(signal) }) catch null;
        },
        else => {
            session.last_error = std.fmt.allocPrint(manager.allocator, "{s} exited unexpectedly", .{session.harness.name()}) catch null;
        },
    };
}

fn writeStatus(writer: *Io.Writer, session: *const Session) !void {
    try writer.print("{{\"running\":{},\"active\":{},\"harness\":", .{ session.running, session.active });
    try std.json.Stringify.value(session.harness.name(), .{}, writer);
    try writer.writeAll(",\"modelId\":");
    try std.json.Stringify.value(session.model_id, .{}, writer);
    try writer.writeAll(",\"cwd\":");
    try std.json.Stringify.value(session.cwd, .{}, writer);
    if (session.harness == .pi) {
        try writer.writeAll(",\"piSessionId\":");
        try std.json.Stringify.value(session.native_id, .{}, writer);
    }
    try writer.writeAll(",\"nativeSessionId\":");
    try std.json.Stringify.value(session.native_id, .{}, writer);
    try writer.writeAll(",\"harnessVersion\":");
    if (session.harness_version) |value| try std.json.Stringify.value(value, .{}, writer) else try writer.writeAll("null");
    try writer.writeAll(",\"capabilities\":");
    try harness_catalog.writeCapabilities(writer, session.harness.name());
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
        try writer.print("{{\"seq\":{d},\"harness\":", .{event.seq});
        try std.json.Stringify.value(session.harness.name(), .{}, writer);
        try writer.writeAll(",\"normalized\":");
        try harness_events.writeNormalized(session.allocator, writer, session.harness.name(), event.document);
        try writer.writeAll(",\"event\":");
        try harness_events.writeCanonical(session.allocator, writer, session.harness.name(), event.document);
        try writer.writeAll(",\"native\":");
        try writer.writeAll(event.document);
        try writer.writeAll(",\"timestamp\":");
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
    if (!harness_session_id.validRuntime(id)) return error.InvalidSessionId;
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

fn optionalBool(object: std.json.ObjectMap, name: []const u8) ?bool {
    const value = object.get(name) orelse return null;
    return if (value == .bool) value.bool else null;
}

fn requiredString(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    return optionalString(object, name);
}

fn configAssignment(allocator: std.mem.Allocator, key: []const u8, value: anytype) ![]u8 {
    var output: Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll(key);
    try output.writer.writeByte('=');
    try std.json.Stringify.value(value, .{}, &output.writer);
    return output.toOwnedSlice();
}

fn validEntryId(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    for (value) |character| if (!std.ascii.isAlphanumeric(character) and character != '-' and character != '_') return false;
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
