const std = @import("std");
const builtin = @import("builtin");
const harness_nodes = @import("../harness/nodes.zig");
const node_transport = @import("../../topology/node_transport.zig");
const sqlite = @import("../../storage/sqlite.zig");

const Io = std.Io;
const max_response_bytes = 512 * 1024;

pub const Manager = struct {
    allocator: std.mem.Allocator,
    io: Io,
    environment: *const std.process.Environ.Map,
    data_dir: []u8,
    preference: []u8,
    mutex: Io.Mutex = .init,
    sessions: std.StringHashMapUnmanaged([]u8) = .empty,
    active_session: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator, io: Io, environment: *const std.process.Environ.Map, data_dir: []const u8) !Manager {
        const owned_data_dir = try allocator.dupe(u8, data_dir);
        errdefer allocator.free(owned_data_dir);
        return .{
            .allocator = allocator,
            .io = io,
            .environment = environment,
            .data_dir = owned_data_dir,
            .preference = try loadPreference(allocator, io, environment, data_dir),
        };
    }

    pub fn deinit(manager: *Manager) void {
        var iterator = manager.sessions.iterator();
        while (iterator.next()) |entry| {
            manager.allocator.free(entry.key_ptr.*);
            manager.allocator.free(entry.value_ptr.*);
        }
        manager.sessions.deinit(manager.allocator);
        if (manager.active_session) |value| manager.allocator.free(value);
        manager.allocator.free(manager.data_dir);
        manager.allocator.free(manager.preference);
        manager.* = undefined;
    }

    pub fn verbPayload(manager: *Manager, client: *std.http.Client, verb: []const u8, document: []const u8) ![]u8 {
        var parsed = std.json.parseFromSlice(std.json.Value, manager.allocator, if (document.len == 0) "{}" else document, .{}) catch return error.InvalidBrowserPayload;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidBrowserPayload;
        const session = sessionKey(parsed.value.object);
        if (std.mem.eql(u8, verb, "navigate")) {
            const raw_url = stringField(parsed.value.object, "url") orelse return browserError(manager.allocator, "valid public or localhost http(s) url required");
            const page = fetchReadable(manager.allocator, manager.io, client, raw_url) catch return browserError(manager.allocator, "Browser navigation failed");
            defer page.deinit();
            try manager.remember(session, page.url);
            var output: Io.Writer.Allocating = .init(manager.allocator);
            errdefer output.deinit();
            try output.writer.writeAll("{\"ok\":true,\"data\":{\"url\":");
            try std.json.Stringify.value(page.url, .{}, &output.writer);
            try output.writer.writeAll(",\"title\":");
            try std.json.Stringify.value(page.title, .{}, &output.writer);
            try output.writer.writeAll(",\"readingMode\":true}}");
            return output.toOwnedSlice();
        }
        if (std.mem.eql(u8, verb, "get-url")) return manager.urlPayload(session);
        if (std.mem.eql(u8, verb, "get-text") or std.mem.eql(u8, verb, "get-html")) {
            const url = stringField(parsed.value.object, "url") orelse try manager.remembered(session) orelse return browserError(manager.allocator, "Browser unavailable");
            defer if (stringField(parsed.value.object, "url") == null) manager.allocator.free(url);
            const page = fetchReadable(manager.allocator, manager.io, client, url) catch return browserError(manager.allocator, "Browser fetch failed");
            defer page.deinit();
            try manager.remember(session, page.url);
            var output: Io.Writer.Allocating = .init(manager.allocator);
            errdefer output.deinit();
            try output.writer.writeAll("{\"ok\":true,\"data\":{");
            try std.json.Stringify.value(if (std.mem.eql(u8, verb, "get-text")) "text" else "html", .{}, &output.writer);
            try output.writer.writeByte(':');
            try std.json.Stringify.value(if (std.mem.eql(u8, verb, "get-text")) page.text else page.body, .{}, &output.writer);
            try output.writer.writeAll(",\"readingMode\":true}}");
            return output.toOwnedSlice();
        }
        return browserError(manager.allocator, "Interactive browser engine unavailable");
    }

    pub fn fetchPayload(manager: *Manager, client: *std.http.Client, url: []const u8) ![]u8 {
        const page = try fetchReadable(manager.allocator, manager.io, client, url);
        defer page.deinit();
        var output: Io.Writer.Allocating = .init(manager.allocator);
        errdefer output.deinit();
        try output.writer.writeAll("{\"url\":");
        try std.json.Stringify.value(page.url, .{}, &output.writer);
        try output.writer.writeAll(",\"title\":");
        try std.json.Stringify.value(page.title, .{}, &output.writer);
        try output.writer.writeAll(",\"text\":");
        try std.json.Stringify.value(page.text, .{}, &output.writer);
        try output.writer.writeAll(",\"contentType\":");
        try std.json.Stringify.value(page.content_type, .{}, &output.writer);
        try output.writer.writeByte('}');
        return output.toOwnedSlice();
    }

    pub fn statePayload(manager: *Manager) ![]u8 {
        const url = try manager.activeUrl();
        defer if (url) |value| manager.allocator.free(value);
        if (url == null) return manager.allocator.dupe(u8, "{\"ok\":false,\"error\":\"Browser unavailable\"}");
        var output: Io.Writer.Allocating = .init(manager.allocator);
        errdefer output.deinit();
        try output.writer.writeAll("{\"ok\":true,\"data\":{\"url\":");
        try std.json.Stringify.value(url.?, .{}, &output.writer);
        try output.writer.writeAll(",\"title\":\"\",\"canGoBack\":false,\"canGoForward\":false,\"readingMode\":true}}");
        return output.toOwnedSlice();
    }

    pub fn historyPayload(manager: *Manager, visited_only: bool) ![]u8 {
        try manager.mutex.lock(manager.io);
        defer manager.mutex.unlock(manager.io);
        var output: Io.Writer.Allocating = .init(manager.allocator);
        errdefer output.deinit();
        try output.writer.writeAll(if (visited_only) "{\"ok\":true,\"data\":{\"visited\":[" else "{\"ok\":true,\"data\":{\"entries\":[");
        var iterator = manager.sessions.iterator();
        var first = true;
        while (iterator.next()) |entry| {
            if (!first) try output.writer.writeByte(',');
            if (visited_only) try std.json.Stringify.value(entry.value_ptr.*, .{}, &output.writer) else {
                try output.writer.writeAll("{\"action\":\"navigate\",\"url\":");
                try std.json.Stringify.value(entry.value_ptr.*, .{}, &output.writer);
                try output.writer.writeAll(",\"ok\":true}");
            }
            first = false;
        }
        try output.writer.writeAll("]}}");
        return output.toOwnedSlice();
    }

    pub fn enginesPayload(manager: *Manager) ![]u8 {
        const engines = try discoverEngines(manager.allocator, manager.io, manager.environment);
        defer {
            for (engines) |entry| {
                manager.allocator.free(entry.id);
                manager.allocator.free(entry.label);
                if (entry.path) |value| manager.allocator.free(value);
            }
            manager.allocator.free(engines);
        }
        var output: Io.Writer.Allocating = .init(manager.allocator);
        errdefer output.deinit();
        try manager.mutex.lock(manager.io);
        defer manager.mutex.unlock(manager.io);
        const override = manager.environment.get("LOCAL_STUDIO_CHROME_PATH");
        const selected = selectEngine(manager.io, engines, manager.preference, override);
        const preferred = engineById(engines, manager.preference);
        try output.writer.writeAll("{\"ok\":true,\"data\":{\"preference\":");
        try std.json.Stringify.value(manager.preference, .{}, &output.writer);
        try output.writer.print(",\"preferenceUnavailable\":{},\"override\":", .{!std.mem.eql(u8, manager.preference, "auto") and (preferred == null or preferred.?.path == null)});
        if (override) |value| try std.json.Stringify.value(value, .{}, &output.writer) else try output.writer.writeAll("null");
        try output.writer.writeAll(",\"active\":");
        if (selected) |entry| {
            try output.writer.writeAll("{\"id\":");
            try std.json.Stringify.value(entry.id, .{}, &output.writer);
            try output.writer.writeAll(",\"label\":");
            try std.json.Stringify.value(entry.label, .{}, &output.writer);
            try output.writer.writeAll(",\"path\":");
            try std.json.Stringify.value(entry.path.?, .{}, &output.writer);
            try output.writer.writeAll(",\"source\":");
            try std.json.Stringify.value(entry.source, .{}, &output.writer);
            try output.writer.writeByte('}');
        } else try output.writer.writeAll("null");
        try output.writer.writeAll(",\"unavailableReason\":");
        if (selected == null) try std.json.Stringify.value("Interactive browser engine unavailable", .{}, &output.writer) else try output.writer.writeAll("null");
        try output.writer.writeAll(",\"engines\":[");
        for (engines, 0..) |entry, index| {
            if (index > 0) try output.writer.writeByte(',');
            try output.writer.writeAll("{\"id\":");
            try std.json.Stringify.value(entry.id, .{}, &output.writer);
            try output.writer.writeAll(",\"label\":");
            try std.json.Stringify.value(entry.label, .{}, &output.writer);
            try output.writer.writeAll(",\"path\":");
            if (entry.path) |value| try std.json.Stringify.value(value, .{}, &output.writer) else try output.writer.writeAll("null");
            try output.writer.writeByte('}');
        }
        try output.writer.writeAll("]}}");
        return output.toOwnedSlice();
    }

    pub fn selectEnginePayload(manager: *Manager, document: []const u8) ![]u8 {
        var parsed = std.json.parseFromSlice(std.json.Value, manager.allocator, document, .{}) catch return error.InvalidBrowserPayload;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidBrowserPayload;
        const engine = stringField(parsed.value.object, "engine") orelse return error.BrowserEngineRequired;
        if (!validEngineId(engine)) return error.UnknownBrowserEngine;
        try manager.mutex.lock(manager.io);
        const replacement = manager.allocator.dupe(u8, engine) catch |failure| {
            manager.mutex.unlock(manager.io);
            return failure;
        };
        persistPreference(manager.allocator, manager.io, manager.data_dir, engine) catch |failure| {
            manager.allocator.free(replacement);
            manager.mutex.unlock(manager.io);
            return failure;
        };
        manager.allocator.free(manager.preference);
        manager.preference = replacement;
        manager.mutex.unlock(manager.io);
        return manager.enginesPayload();
    }

    fn remember(manager: *Manager, session_value: []const u8, url: []const u8) !void {
        try manager.mutex.lock(manager.io);
        defer manager.mutex.unlock(manager.io);
        if (manager.sessions.getPtr(session_value)) |existing| {
            manager.allocator.free(existing.*);
            existing.* = try manager.allocator.dupe(u8, url);
        } else {
            try manager.sessions.put(manager.allocator, try manager.allocator.dupe(u8, session_value), try manager.allocator.dupe(u8, url));
        }
        if (manager.active_session) |value| manager.allocator.free(value);
        manager.active_session = try manager.allocator.dupe(u8, session_value);
    }

    fn remembered(manager: *Manager, session_value: []const u8) !?[]u8 {
        try manager.mutex.lock(manager.io);
        defer manager.mutex.unlock(manager.io);
        return if (manager.sessions.get(session_value)) |value| try manager.allocator.dupe(u8, value) else null;
    }

    fn activeUrl(manager: *Manager) !?[]u8 {
        try manager.mutex.lock(manager.io);
        defer manager.mutex.unlock(manager.io);
        const session = manager.active_session orelse return null;
        return if (manager.sessions.get(session)) |value| try manager.allocator.dupe(u8, value) else null;
    }

    fn urlPayload(manager: *Manager, session: []const u8) ![]u8 {
        const url = try manager.remembered(session);
        defer if (url) |value| manager.allocator.free(value);
        var output: Io.Writer.Allocating = .init(manager.allocator);
        errdefer output.deinit();
        try output.writer.writeAll("{\"ok\":true,\"data\":{\"url\":");
        try std.json.Stringify.value(url orelse "", .{}, &output.writer);
        try output.writer.writeAll(",\"title\":\"\"}}");
        return output.toOwnedSlice();
    }
};

pub fn remotePayload(allocator: std.mem.Allocator, io: Io, client: *std.http.Client, database: *sqlite.Database, target: []const u8, method: std.http.Method, document: ?[]const u8, preferred_node: ?[]const u8) ![]u8 {
    var node = (try harness_nodes.selectCapability(allocator, io, database, "browser", preferred_node)) orelse return error.BrowserNodeRequired;
    defer node.deinit();
    const prefix = "/api/agent/browser";
    if (!std.mem.startsWith(u8, target, prefix)) return error.InvalidBrowserPath;
    const path = try std.fmt.allocPrint(allocator, "/internal/node/v1/browser{s}", .{target[prefix.len..]});
    defer allocator.free(path);
    return if (method == .GET)
        node_transport.get(allocator, client, &node, path) catch |failure| switch (failure) {
            error.NodeUnavailable => error.BrowserNodeUnavailable,
            else => failure,
        }
    else
        node_transport.send(allocator, client, &node, path, method, document) catch |failure| switch (failure) {
            error.NodeRequestRejected => error.BrowserNodeUnavailable,
            else => failure,
        };
}

const Page = struct {
    allocator: std.mem.Allocator,
    url: []u8,
    title: []u8,
    text: []u8,
    body: []u8,
    content_type: []u8,

    fn deinit(page: *const Page) void {
        page.allocator.free(page.url);
        page.allocator.free(page.title);
        page.allocator.free(page.text);
        page.allocator.free(page.body);
        page.allocator.free(page.content_type);
    }
};

fn fetchReadable(allocator: std.mem.Allocator, io: Io, client: *std.http.Client, raw_url: []const u8) !Page {
    try validateUrl(io, raw_url);
    const storage = try allocator.alloc(u8, max_response_bytes);
    defer allocator.free(storage);
    var body: Io.Writer = .fixed(storage);
    const response = try client.fetch(.{
        .location = .{ .url = raw_url },
        .redirect_behavior = .not_allowed,
        .keep_alive = false,
        .headers = .{ .accept_encoding = .omit },
        .extra_headers = &.{
            .{ .name = "Accept", .value = "text/html,application/xhtml+xml,application/xml;q=0.9,text/plain;q=0.8,*/*;q=0.5" },
            .{ .name = "User-Agent", .value = "Local-Studio-Zig/1.0" },
        },
        .response_writer = &body,
    });
    if (@intFromEnum(response.status) >= 300 and @intFromEnum(response.status) < 400) return error.BrowserRedirectUnsupported;
    if (response.status.class() != .success) return error.BrowserUpstreamRejected;
    const content_type = "text/html";
    const owned_body = try allocator.dupe(u8, body.buffered());
    errdefer allocator.free(owned_body);
    const title = try htmlTitle(allocator, owned_body, raw_url);
    errdefer allocator.free(title);
    const text = try readableText(allocator, owned_body);
    errdefer allocator.free(text);
    return .{
        .allocator = allocator,
        .url = try allocator.dupe(u8, raw_url),
        .title = title,
        .text = text,
        .body = owned_body,
        .content_type = try allocator.dupe(u8, content_type),
    };
}

fn validateUrl(io: Io, raw_url: []const u8) !void {
    if (raw_url.len == 0 or raw_url.len > 8192) return error.InvalidBrowserUrl;
    const uri = std.Uri.parse(raw_url) catch return error.InvalidBrowserUrl;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.InvalidBrowserUrl;
    var host_buffer: [Io.net.HostName.max_len]u8 = undefined;
    const host = (try uri.getHost(&host_buffer)).bytes;
    const loopback_name = std.ascii.eqlIgnoreCase(host, "localhost");
    var lookup_buffer: [32]Io.net.HostName.LookupResult = undefined;
    var queue: Io.Queue(Io.net.HostName.LookupResult) = .init(&lookup_buffer);
    var future = io.async(Io.net.HostName.lookup, .{ try Io.net.HostName.init(host), io, &queue, .{ .port = uri.port orelse if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) 443 else 80 } });
    defer future.cancel(io) catch {};
    var found = false;
    while (queue.getOne(io)) |result| switch (result) {
        .canonical_name => {},
        .address => |address| {
            found = true;
            if (!addressAllowed(address, loopback_name)) return error.BrowserAddressRejected;
        },
    } else |failure| switch (failure) {
        error.Closed => try future.await(io),
        else => return failure,
    }
    if (!found) return error.BrowserAddressRejected;
}

fn addressAllowed(address: Io.net.IpAddress, allow_loopback: bool) bool {
    return switch (address) {
        .ip4 => |value| blk: {
            const b = value.bytes;
            const loopback = b[0] == 127;
            if (loopback) break :blk allow_loopback;
            break :blk b[0] != 10 and !(b[0] == 172 and b[1] >= 16 and b[1] <= 31) and !(b[0] == 192 and b[1] == 168) and !(b[0] == 169 and b[1] == 254) and b[0] != 0 and b[0] < 224;
        },
        .ip6 => |value| blk: {
            const b = value.bytes;
            const loopback = std.mem.allEqual(u8, b[0..15], 0) and b[15] == 1;
            if (loopback) break :blk allow_loopback;
            break :blk (b[0] & 0xfe) != 0xfc and !(b[0] == 0xfe and (b[1] & 0xc0) == 0x80) and !std.mem.allEqual(u8, &b, 0);
        },
    };
}

fn htmlTitle(allocator: std.mem.Allocator, body: []const u8, fallback: []const u8) ![]u8 {
    const start = std.ascii.indexOfIgnoreCase(body, "<title");
    if (start) |index| {
        const close = std.mem.findScalarPos(u8, body, index, '>') orelse return allocator.dupe(u8, fallback);
        const end = std.ascii.indexOfIgnoreCase(body[close + 1 ..], "</title>") orelse return allocator.dupe(u8, fallback);
        return allocator.dupe(u8, std.mem.trim(u8, body[close + 1 .. close + 1 + end], " \t\r\n"));
    }
    return allocator.dupe(u8, fallback);
}

fn readableText(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    var output: Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    var in_tag = false;
    var pending_space = false;
    for (body) |character| {
        if (character == '<') {
            in_tag = true;
            pending_space = true;
        } else if (character == '>') {
            in_tag = false;
        } else if (!in_tag) {
            if (std.ascii.isWhitespace(character)) {
                pending_space = true;
            } else {
                if (pending_space and output.writer.buffered().len > 0) try output.writer.writeByte(' ');
                try output.writer.writeByte(character);
                pending_space = false;
            }
        }
    }
    return output.toOwnedSlice();
}

const Engine = struct { id: []u8, label: []u8, path: ?[]u8 };
const ResolvedEngine = struct { id: []const u8, label: []const u8, path: ?[]const u8, source: []const u8 };

fn discoverEngines(allocator: std.mem.Allocator, io: Io, environment: *const std.process.Environ.Map) ![]Engine {
    const candidates: []const [3][]const u8 = switch (builtin.os.tag) {
        .macos => &[_][3][]const u8{
            .{ "chrome", "Google Chrome", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" },
            .{ "chromium", "Chromium", "/Applications/Chromium.app/Contents/MacOS/Chromium" },
            .{ "brave", "Brave", "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser" },
            .{ "edge", "Microsoft Edge", "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" },
            .{ "arc", "Arc", "/Applications/Arc.app/Contents/MacOS/Arc" },
            .{ "vivaldi", "Vivaldi", "/Applications/Vivaldi.app/Contents/MacOS/Vivaldi" },
        },
        .linux => &[_][3][]const u8{
            .{ "chromium", "Chromium", "/usr/bin/chromium" },
            .{ "chrome", "Google Chrome", "/usr/bin/google-chrome" },
            .{ "brave", "Brave", "/usr/bin/brave-browser" },
            .{ "edge", "Microsoft Edge", "/usr/bin/microsoft-edge" },
            .{ "vivaldi", "Vivaldi", "/usr/bin/vivaldi" },
        },
        else => &[_][3][]const u8{},
    };
    var engines = try allocator.alloc(Engine, candidates.len + 2);
    engines[0] = .{ .id = try allocator.dupe(u8, "auto"), .label = try allocator.dupe(u8, "Automatic"), .path = null };
    const bundled = environment.get("LOCAL_STUDIO_BUNDLED_CHROMIUM_PATH");
    engines[1] = .{ .id = try allocator.dupe(u8, "bundled"), .label = try allocator.dupe(u8, "Bundled Chromium"), .path = if (bundled) |value| if (pathAvailable(io, value)) try allocator.dupe(u8, value) else null else null };
    for (candidates, 0..) |candidate, index| engines[index + 2] = .{
        .id = try allocator.dupe(u8, candidate[0]),
        .label = try allocator.dupe(u8, candidate[1]),
        .path = if (pathAvailable(io, candidate[2])) try allocator.dupe(u8, candidate[2]) else null,
    };
    for (engines[1..]) |entry| if (entry.path) |value| {
        engines[0].path = try allocator.dupe(u8, value);
        break;
    };
    return engines;
}

fn selectEngine(io: Io, engines: []const Engine, preference: []const u8, override: ?[]const u8) ?ResolvedEngine {
    if (override) |path| if (pathAvailable(io, path)) return .{ .id = "custom", .label = "Custom", .path = path, .source = "override" };
    if (!std.mem.eql(u8, preference, "auto")) if (engineById(engines, preference)) |entry| if (entry.path != null) return .{ .id = entry.id, .label = entry.label, .path = entry.path, .source = "preference" };
    const automatic = engineById(engines, "auto") orelse return null;
    const path = automatic.path orelse return null;
    for (engines[1..]) |entry| if (entry.path) |candidate| if (std.mem.eql(u8, candidate, path)) return .{
        .id = entry.id,
        .label = entry.label,
        .path = entry.path,
        .source = if (std.mem.eql(u8, entry.id, "bundled")) "bundled" else "detected",
    };
    return null;
}

fn engineById(engines: []const Engine, id: []const u8) ?Engine {
    for (engines) |entry| if (std.mem.eql(u8, entry.id, id)) return entry;
    return null;
}

fn pathAvailable(io: Io, path: []const u8) bool {
    if (!std.fs.path.isAbsolute(path)) return false;
    _ = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

fn loadPreference(allocator: std.mem.Allocator, io: Io, environment: *const std.process.Environ.Map, data_dir: []const u8) ![]u8 {
    const preference_path = try std.fs.path.join(allocator, &.{ data_dir, "browser-engine.json" });
    defer allocator.free(preference_path);
    const document = Io.Dir.cwd().readFileAlloc(io, preference_path, allocator, .limited(4096)) catch |failure| switch (failure) {
        error.FileNotFound => null,
        else => return failure,
    };
    if (document) |value| {
        defer allocator.free(value);
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, value, .{}) catch null;
        if (parsed) |*body| {
            defer body.deinit();
            if (body.value == .object) if (stringField(body.value.object, "engine")) |engine| if (validEngineId(engine)) return allocator.dupe(u8, engine);
        }
    }
    const configured = environment.get("LOCAL_STUDIO_BROWSER_ENGINE") orelse "auto";
    return allocator.dupe(u8, if (validEngineId(configured)) configured else "auto");
}

fn persistPreference(allocator: std.mem.Allocator, io: Io, data_dir: []const u8, engine: []const u8) !void {
    const preference_path = try std.fs.path.join(allocator, &.{ data_dir, "browser-engine.json" });
    defer allocator.free(preference_path);
    var output: Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try output.writer.writeAll("{\"engine\":");
    try std.json.Stringify.value(engine, .{}, &output.writer);
    try output.writer.writeByte('}');
    var atomic_file = try Io.Dir.cwd().createFileAtomic(io, preference_path, .{ .permissions = @enumFromInt(0o600), .make_path = true, .replace = true });
    defer atomic_file.deinit(io);
    try atomic_file.file.writeStreamingAll(io, output.writer.buffered());
    try atomic_file.file.sync(io);
    try atomic_file.replace(io);
}

fn validEngineId(value: []const u8) bool {
    for ([_][]const u8{ "auto", "bundled", "chrome", "chromium", "brave", "edge", "arc", "vivaldi" }) |candidate| if (std.mem.eql(u8, value, candidate)) return true;
    return false;
}

fn sessionKey(object: std.json.ObjectMap) []const u8 {
    const value = stringField(object, "sessionId") orelse return "shared";
    if (value.len > 128) return "shared";
    for (value) |character| if (!std.ascii.isAlphanumeric(character) and character != '.' and character != '_' and character != ':' and character != '-') return "shared";
    return value;
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

fn browserError(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    var output: Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"ok\":false,\"error\":");
    try std.json.Stringify.value(message, .{}, &output.writer);
    try output.writer.writeByte('}');
    return output.toOwnedSlice();
}
