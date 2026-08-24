const std = @import("std");
const config = @import("../config.zig");

const Io = std.Io;

pub const Installation = struct {
    allocator: std.mem.Allocator,
    source: []u8,
    executable: []u8,
    version: ?[]u8,
    rpc_supported: bool,

    pub fn deinit(installation: *Installation) void {
        installation.allocator.free(installation.source);
        installation.allocator.free(installation.executable);
        if (installation.version) |value| installation.allocator.free(value);
        installation.* = undefined;
    }

    pub fn available(installation: *const Installation) bool {
        return installation.version != null and installation.rpc_supported;
    }
};

pub fn discoverPi(allocator: std.mem.Allocator, io: Io, configuration: *const config.Config) !Installation {
    if (configuration.environment.get("LOCAL_STUDIO_PI_BIN")) |configured| {
        const trimmed = std.mem.trim(u8, configured, " \t\r\n");
        if (trimmed.len > 0) return probePi(allocator, io, configuration.environment, "configured", trimmed);
    }
    if (try managedPi(allocator, io, configuration)) |managed| return managed;
    if (try pathExecutable(allocator, io, configuration.environment, "pi")) |executable| {
        defer allocator.free(executable);
        return probePi(allocator, io, configuration.environment, "system", executable);
    }
    for (knownPiLocations()) |candidate| {
        if (!executableFile(io, candidate)) continue;
        return probePi(allocator, io, configuration.environment, "system", candidate);
    }
    return .{
        .allocator = allocator,
        .source = try allocator.dupe(u8, "missing"),
        .executable = try allocator.dupe(u8, "pi"),
        .version = null,
        .rpc_supported = false,
    };
}

pub fn writeCatalog(writer: *Io.Writer, pi: *const Installation) !void {
    try writer.writeAll("{\"harnesses\":[");
    try writePi(writer, pi);
    try writer.writeAll(",");
    try writeFx(writer);
    try writer.writeAll(",");
    try writeUnavailable(writer, "opencode", "OpenCode", "http-sse");
    try writer.writeAll(",");
    try writeUnavailable(writer, "codex", "Codex", "app-server");
    try writer.writeAll(",");
    try writeUnavailable(writer, "claude", "Claude Code", "stream-json");
    try writer.writeAll("]}");
}

pub fn writeCapabilities(writer: *Io.Writer, harness: []const u8) !void {
    if (std.mem.eql(u8, harness, "pi")) return writer.writeAll("[\"persistent-session\",\"resume\",\"steer\",\"follow-up\",\"cancel\",\"images\",\"compact\",\"extension-ui\",\"extension-mcp\"]");
    if (std.mem.eql(u8, harness, "fx")) return writer.writeAll("[\"persistent-session\",\"cancel\",\"mcp\",\"filesystem-free\"]");
    try writer.writeAll("[]");
}

fn managedPi(allocator: std.mem.Allocator, io: Io, configuration: *const config.Config) !?Installation {
    const root = try std.fs.path.join(allocator, &.{ configuration.data_dir, "harnesses", "pi" });
    defer allocator.free(root);
    var directory = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return null;
    defer directory.close(io);
    var iterator = directory.iterateAssumeFirstIteration();
    var selected: ?[]u8 = null;
    defer if (selected) |value| allocator.free(value);
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory or entry.name.len == 0) continue;
        if (selected == null or versionOrder(entry.name, selected.?) == .gt) {
            if (selected) |value| allocator.free(value);
            selected = try allocator.dupe(u8, entry.name);
        }
    }
    const version = selected orelse return null;
    const executable = try std.fs.path.join(allocator, &.{ root, version, "bin", "pi" });
    defer allocator.free(executable);
    if (!executableFile(io, executable)) return null;
    return try probePi(allocator, io, configuration.environment, "managed", executable);
}

fn versionOrder(left: []const u8, right: []const u8) std.math.Order {
    const left_version = std.SemanticVersion.parse(left) catch return std.mem.order(u8, left, right);
    const right_version = std.SemanticVersion.parse(right) catch return std.mem.order(u8, left, right);
    return left_version.order(right_version);
}

fn pathExecutable(allocator: std.mem.Allocator, io: Io, environment: *const std.process.Environ.Map, name: []const u8) !?[]u8 {
    const path_value = environment.get("PATH") orelse return null;
    var directories = std.mem.splitScalar(u8, path_value, std.fs.path.delimiter);
    while (directories.next()) |directory| {
        if (directory.len == 0) continue;
        const candidate = try std.fs.path.join(allocator, &.{ directory, name });
        defer allocator.free(candidate);
        if (!executableFile(io, candidate)) continue;
        const absolute = if (std.fs.path.isAbsolute(candidate)) try allocator.dupe(u8, candidate) else try std.fs.path.resolve(allocator, &.{candidate});
        defer allocator.free(absolute);
        const resolved = Io.Dir.realPathFileAbsoluteAlloc(io, absolute, allocator) catch return try allocator.dupe(u8, absolute);
        defer allocator.free(resolved);
        return try allocator.dupe(u8, resolved);
    }
    return null;
}

fn probePi(allocator: std.mem.Allocator, io: Io, environment: *const std.process.Environ.Map, source: []const u8, executable: []const u8) !Installation {
    const owned_source = try allocator.dupe(u8, source);
    errdefer allocator.free(owned_source);
    const owned_executable = try allocator.dupe(u8, executable);
    errdefer allocator.free(owned_executable);
    const version = commandOutput(allocator, io, environment, &.{ executable, "--version" });
    errdefer if (version) |value| allocator.free(value);
    const help = commandOutput(allocator, io, environment, &.{ executable, "--help" });
    defer if (help) |value| allocator.free(value);
    return .{
        .allocator = allocator,
        .source = owned_source,
        .executable = owned_executable,
        .version = version,
        .rpc_supported = if (help) |value| std.mem.indexOf(u8, value, "--mode") != null and std.mem.indexOf(u8, value, "rpc") != null else false,
    };
}

fn commandOutput(allocator: std.mem.Allocator, io: Io, environment: *const std.process.Environ.Map, argv: []const []const u8) ?[]u8 {
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .environ_map = environment,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(3) } },
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const successful = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!successful) return null;
    const output = std.mem.trim(u8, if (result.stdout.len > 0) result.stdout else result.stderr, " \t\r\n");
    if (output.len == 0) return null;
    return allocator.dupe(u8, output) catch null;
}

fn executableFile(io: Io, path: []const u8) bool {
    const stat = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .file and stat.permissions.toMode() & 0o111 != 0;
}

fn writePi(writer: *Io.Writer, installation: *const Installation) !void {
    try writer.writeAll("{\"id\":\"pi\",\"name\":\"Pi\",\"status\":");
    try std.json.Stringify.value(if (installation.available()) "available" else if (installation.version != null) "unsupported" else "missing", .{}, writer);
    try writer.writeAll(",\"transport\":\"jsonl-rpc\",\"installation\":{\"source\":");
    try std.json.Stringify.value(installation.source, .{}, writer);
    try writer.writeAll(",\"executable\":");
    try std.json.Stringify.value(installation.executable, .{}, writer);
    try writer.writeAll(",\"version\":");
    if (installation.version) |value| try std.json.Stringify.value(value, .{}, writer) else try writer.writeAll("null");
    try writer.writeAll("},\"capabilities\":");
    try writeCapabilities(writer, "pi");
    try writer.writeByte('}');
}

fn writeFx(writer: *Io.Writer) !void {
    try writer.writeAll("{\"id\":\"fx\",\"name\":\"FX\",\"status\":\"available\",\"transport\":\"embedded-acp\",\"installation\":{\"source\":\"embedded\",\"executable\":\"self\",\"version\":\"0.0.0-local-studio\"},\"capabilities\":");
    try writeCapabilities(writer, "fx");
    try writer.writeByte('}');
}

fn writeUnavailable(writer: *Io.Writer, id: []const u8, name: []const u8, transport: []const u8) !void {
    try writer.writeAll("{\"id\":");
    try std.json.Stringify.value(id, .{}, writer);
    try writer.writeAll(",\"name\":");
    try std.json.Stringify.value(name, .{}, writer);
    try writer.writeAll(",\"status\":\"driver-unavailable\",\"transport\":");
    try std.json.Stringify.value(transport, .{}, writer);
    try writer.writeAll(",\"installation\":null,\"capabilities\":[]}");
}

fn knownPiLocations() []const []const u8 {
    return &.{ "/opt/homebrew/bin/pi", "/usr/local/bin/pi", "/usr/bin/pi" };
}
