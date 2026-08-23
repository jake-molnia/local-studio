const std = @import("std");
const config = @import("../config.zig");
const sqlite = @import("../repository/sqlite.zig");
const harness_nodes = @import("harness_nodes.zig");
const node_transport = @import("node_transport.zig");

const Io = std.Io;
const http = std.http;
const max_source_bytes = 256 * 1024;

const Plugin = struct {
    allocator: std.mem.Allocator,
    id: []u8,
    file: []u8,
    path: []u8,
    enabled: bool,
    bytes: u64,
    modified_seconds: i64,
    read_only: bool,

    fn deinit(plugin: *Plugin) void {
        plugin.allocator.free(plugin.id);
        plugin.allocator.free(plugin.file);
        plugin.allocator.free(plugin.path);
        plugin.* = undefined;
    }
};

pub fn listPayload(allocator: std.mem.Allocator, io: Io, mode: config.Mode, environment: *const std.process.Environ.Map, client: *http.Client, database: *sqlite.Database, preferred_node: ?[]const u8) ![]u8 {
    if (mode == .standalone) return listLocal(allocator, io, environment);
    return remote(allocator, io, client, database, preferred_node, "/internal/node/v1/plugins", .GET, null);
}

pub fn sourcePayload(allocator: std.mem.Allocator, io: Io, mode: config.Mode, environment: *const std.process.Environ.Map, client: *http.Client, database: *sqlite.Database, preferred_node: ?[]const u8, id: []const u8) ![]u8 {
    if (mode == .standalone) return sourceLocal(allocator, io, environment, id);
    const encoded = try queryEncode(allocator, id);
    defer allocator.free(encoded);
    const path = try std.fmt.allocPrint(allocator, "/internal/node/v1/plugins/source?id={s}", .{encoded});
    defer allocator.free(path);
    return remote(allocator, io, client, database, preferred_node, path, .GET, null);
}

pub fn upsertPayload(allocator: std.mem.Allocator, io: Io, mode: config.Mode, environment: *const std.process.Environ.Map, client: *http.Client, database: *sqlite.Database, preferred_node: ?[]const u8, document: []const u8) ![]u8 {
    if (mode == .standalone) return upsertLocal(allocator, io, environment, document);
    return remote(allocator, io, client, database, preferred_node, "/internal/node/v1/plugins", .POST, document);
}

pub fn deletePayload(allocator: std.mem.Allocator, io: Io, mode: config.Mode, environment: *const std.process.Environ.Map, client: *http.Client, database: *sqlite.Database, preferred_node: ?[]const u8, id: []const u8) ![]u8 {
    if (mode == .standalone) return deleteLocal(allocator, io, environment, id);
    const encoded = try queryEncode(allocator, id);
    defer allocator.free(encoded);
    const path = try std.fmt.allocPrint(allocator, "/internal/node/v1/plugins?id={s}", .{encoded});
    defer allocator.free(path);
    return remote(allocator, io, client, database, preferred_node, path, .DELETE, null);
}

pub fn listLocal(allocator: std.mem.Allocator, io: Io, environment: *const std.process.Environ.Map) ![]u8 {
    const directory = try pluginsDirectory(allocator, environment);
    defer allocator.free(directory);
    var plugins = try list(allocator, io, directory);
    defer deinitPlugins(allocator, &plugins);
    return listingPayload(allocator, directory, plugins.items);
}

pub fn sourceLocal(allocator: std.mem.Allocator, io: Io, environment: *const std.process.Environ.Map, id: []const u8) ![]u8 {
    const directory = try pluginsDirectory(allocator, environment);
    defer allocator.free(directory);
    var plugins = try list(allocator, io, directory);
    defer deinitPlugins(allocator, &plugins);
    const plugin = find(plugins.items, id) orelse return error.PluginNotFound;
    if (plugin.read_only) return error.PluginReadOnly;
    const source = try Io.Dir.cwd().readFileAlloc(io, plugin.path, allocator, .limited(max_source_bytes));
    defer allocator.free(source);
    var output: Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"plugin\":");
    try writePlugin(&output.writer, plugin);
    try output.writer.writeAll(",\"source\":");
    try std.json.Stringify.value(source, .{}, &output.writer);
    try output.writer.writeByte('}');
    return output.toOwnedSlice();
}

pub fn upsertLocal(allocator: std.mem.Allocator, io: Io, environment: *const std.process.Environ.Map, document: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, document, .{}) catch return error.InvalidPluginPayload;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidPluginPayload;
    const id = stringField(parsed.value.object, "id") orelse return error.PluginIdRequired;
    const source = nullableStringField(parsed.value.object, "source");
    const enabled = boolField(parsed.value.object, "enabled");
    if (source == null and enabled == null) return error.InvalidPluginPayload;
    if (source) |value| if (value.len > max_source_bytes) return error.PluginSourceTooLarge;
    const directory = try pluginsDirectory(allocator, environment);
    defer allocator.free(directory);
    _ = try Io.Dir.cwd().createDirPathStatus(io, directory, @enumFromInt(0o700));
    var plugins = try list(allocator, io, directory);
    defer deinitPlugins(allocator, &plugins);
    var existing = find(plugins.items, id);
    if (existing) |plugin| if (plugin.read_only) return error.PluginReadOnly;
    if (existing == null and !validPluginId(id)) return error.InvalidPluginId;
    if (source) |value| {
        var created_file: ?[]u8 = null;
        defer if (created_file) |file| allocator.free(file);
        const file = if (existing) |plugin| plugin.file else created: {
            created_file = try std.fmt.allocPrint(allocator, "{s}.ts", .{id});
            break :created created_file.?;
        };
        const target = try std.fs.path.join(allocator, &.{ directory, file });
        defer allocator.free(target);
        var atomic_file = try Io.Dir.cwd().createFileAtomic(io, target, .{ .permissions = @enumFromInt(0o600), .make_path = true, .replace = true });
        defer atomic_file.deinit(io);
        try atomic_file.file.writeStreamingAll(io, value);
        try atomic_file.file.sync(io);
        try atomic_file.replace(io);
        if (existing == null) {
            deinitPlugins(allocator, &plugins);
            plugins = try list(allocator, io, directory);
            existing = find(plugins.items, id);
        }
    }
    if (enabled) |wanted| {
        const plugin = existing orelse return error.PluginNotFound;
        if (plugin.enabled != wanted) {
            const target_file = if (wanted) plugin.file[0 .. plugin.file.len - ".off".len] else try std.fmt.allocPrint(allocator, "{s}.off", .{plugin.file});
            defer if (!wanted) allocator.free(target_file);
            const target = try std.fs.path.join(allocator, &.{ directory, target_file });
            defer allocator.free(target);
            try Io.Dir.cwd().rename(plugin.path, Io.Dir.cwd(), target, io);
        }
    }
    return listLocal(allocator, io, environment);
}

pub fn deleteLocal(allocator: std.mem.Allocator, io: Io, environment: *const std.process.Environ.Map, id: []const u8) ![]u8 {
    const directory = try pluginsDirectory(allocator, environment);
    defer allocator.free(directory);
    var plugins = try list(allocator, io, directory);
    defer deinitPlugins(allocator, &plugins);
    const plugin = find(plugins.items, id) orelse return error.PluginNotFound;
    if (plugin.read_only) return error.PluginReadOnly;
    try Io.Dir.cwd().deleteFile(io, plugin.path);
    return listLocal(allocator, io, environment);
}

fn remote(allocator: std.mem.Allocator, io: Io, client: *http.Client, database: *sqlite.Database, preferred_node: ?[]const u8, path: []const u8, method: http.Method, document: ?[]const u8) ![]u8 {
    var target = (try harness_nodes.selectCapability(allocator, io, database, "terminal", preferred_node)) orelse return error.PluginNodeRequired;
    defer target.deinit();
    return if (method == .GET)
        node_transport.get(allocator, client, &target, path) catch error.PluginNodeUnavailable
    else
        node_transport.send(allocator, client, &target, path, method, document) catch error.PluginNodeUnavailable;
}

fn pluginsDirectory(allocator: std.mem.Allocator, environment: *const std.process.Environ.Map) ![]u8 {
    if (environment.get("PI_CODING_AGENT_DIR")) |configured| {
        const root = if (std.fs.path.isAbsolute(configured)) try allocator.dupe(u8, configured) else try std.fs.path.resolve(allocator, &.{configured});
        defer allocator.free(root);
        return std.fs.path.join(allocator, &.{ root, "extensions" });
    }
    const home = environment.get("HOME") orelse return error.HomeDirectoryUnavailable;
    return std.fs.path.join(allocator, &.{ home, ".pi", "agent", "extensions" });
}

fn list(allocator: std.mem.Allocator, io: Io, directory_path: []const u8) !std.ArrayList(Plugin) {
    var plugins: std.ArrayList(Plugin) = .empty;
    errdefer deinitPlugins(allocator, &plugins);
    var directory = Io.Dir.cwd().openDir(io, directory_path, .{ .iterate = true }) catch |failure| switch (failure) {
        error.FileNotFound => return plugins,
        else => return failure,
    };
    defer directory.close(io);
    var iterator = directory.iterateAssumeFirstIteration();
    while (try iterator.next(io)) |entry| {
        const file_plugin = extensionFile(entry.name);
        const directory_plugin = entry.kind == .directory and directoryLoads(allocator, io, directory_path, entry.name);
        if (!file_plugin and !directory_plugin) continue;
        const path = try std.fs.path.join(allocator, &.{ directory_path, entry.name });
        errdefer allocator.free(path);
        const stat = Io.Dir.cwd().statFile(io, path, .{}) catch {
            allocator.free(path);
            continue;
        };
        try plugins.append(allocator, .{
            .allocator = allocator,
            .id = try pluginId(allocator, entry.name),
            .file = try allocator.dupe(u8, entry.name),
            .path = path,
            .enabled = !disabledFile(entry.name),
            .bytes = stat.size,
            .modified_seconds = std.math.cast(i64, @divTrunc(stat.mtime.nanoseconds, std.time.ns_per_s)) orelse 0,
            .read_only = directory_plugin,
        });
    }
    std.mem.sort(Plugin, plugins.items, {}, struct {
        fn less(_: void, left: Plugin, right: Plugin) bool {
            return std.mem.order(u8, left.id, right.id) == .lt;
        }
    }.less);
    return plugins;
}

fn directoryLoads(allocator: std.mem.Allocator, io: Io, directory: []const u8, name: []const u8) bool {
    for ([_][]const u8{ "index.ts", "index.js" }) |filename| {
        const path = std.fs.path.join(allocator, &.{ directory, name, filename }) catch continue;
        defer allocator.free(path);
        _ = Io.Dir.cwd().statFile(io, path, .{}) catch continue;
        return true;
    }
    const manifest_path = std.fs.path.join(allocator, &.{ directory, name, "package.json" }) catch return false;
    defer allocator.free(manifest_path);
    const document = Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .limited(64 * 1024)) catch return false;
    defer allocator.free(document);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, document, .{}) catch return false;
    defer parsed.deinit();
    return parsed.value == .object and parsed.value.object.contains("pi");
}

fn listingPayload(allocator: std.mem.Allocator, directory: []const u8, plugins: []const Plugin) ![]u8 {
    var output: Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"directory\":");
    try std.json.Stringify.value(directory, .{}, &output.writer);
    try output.writer.writeAll(",\"plugins\":[");
    for (plugins, 0..) |plugin, index| {
        if (index > 0) try output.writer.writeByte(',');
        try writePlugin(&output.writer, &plugin);
    }
    try output.writer.writeAll("]}");
    return output.toOwnedSlice();
}

fn writePlugin(writer: *Io.Writer, plugin: *const Plugin) !void {
    try writer.writeAll("{\"id\":");
    try std.json.Stringify.value(plugin.id, .{}, writer);
    try writer.writeAll(",\"file\":");
    try std.json.Stringify.value(plugin.file, .{}, writer);
    try writer.writeAll(",\"path\":");
    try std.json.Stringify.value(plugin.path, .{}, writer);
    try writer.print(",\"enabled\":{},\"bytes\":{d},\"updated_at\":", .{ plugin.enabled, plugin.bytes });
    var buffer: [24]u8 = undefined;
    try std.json.Stringify.value(formatTimestamp(plugin.modified_seconds, &buffer), .{}, writer);
    try writer.print(",\"read_only\":{}}}", .{plugin.read_only});
}

fn formatTimestamp(seconds: i64, buffer: *[24]u8) []const u8 {
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(seconds, 0)) };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.000Z", .{ year_day.year, month_day.month.numeric(), month_day.day_index + 1, day_seconds.getHoursIntoDay(), day_seconds.getMinutesIntoHour(), day_seconds.getSecondsIntoMinute() }) catch unreachable;
}

fn pluginId(allocator: std.mem.Allocator, file: []const u8) ![]u8 {
    const active = if (disabledFile(file)) file[0 .. file.len - ".off".len] else file;
    const id = active[0 .. active.len - 3];
    return allocator.dupe(u8, id);
}

fn extensionFile(value: []const u8) bool {
    return std.mem.endsWith(u8, value, ".ts") or std.mem.endsWith(u8, value, ".js") or disabledFile(value);
}

fn disabledFile(value: []const u8) bool {
    if (!std.mem.endsWith(u8, value, ".off")) return false;
    const active = value[0 .. value.len - ".off".len];
    return std.mem.endsWith(u8, active, ".ts") or std.mem.endsWith(u8, active, ".js");
}

fn validPluginId(value: []const u8) bool {
    if (value.len == 0 or value.len > 48 or !std.ascii.isLower(value[0]) and !std.ascii.isDigit(value[0])) return false;
    for (value) |character| if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '-') return false;
    return true;
}

fn find(plugins: []Plugin, id: []const u8) ?*Plugin {
    for (plugins) |*plugin| if (std.mem.eql(u8, plugin.id, id)) return plugin;
    return null;
}

fn deinitPlugins(allocator: std.mem.Allocator, plugins: *std.ArrayList(Plugin)) void {
    for (plugins.items) |*plugin| plugin.deinit();
    plugins.deinit(allocator);
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return if (value == .string) std.mem.trim(u8, value.string, " \t\r\n") else null;
}

fn nullableStringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    return stringField(object, name);
}

fn boolField(object: std.json.ObjectMap, name: []const u8) ?bool {
    const value = object.get(name) orelse return null;
    return if (value == .bool) value.bool else null;
}

fn queryEncode(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var output: Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    for (value) |character| {
        if (std.ascii.isAlphanumeric(character) or character == '-' or character == '_' or character == '.' or character == '~') try output.writer.writeByte(character) else try output.writer.print("%{X:0>2}", .{character});
    }
    return output.toOwnedSlice();
}
