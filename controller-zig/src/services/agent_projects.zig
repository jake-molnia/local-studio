const std = @import("std");
const config = @import("../config.zig");
const repository = @import("../repository/agent_projects.zig");
const sqlite = @import("../repository/sqlite.zig");
const harness_nodes = @import("harness_nodes.zig");
const node_transport = @import("node_transport.zig");

const Io = std.Io;
const http = std.http;
const chats_id = "chats";

pub fn listPayload(allocator: std.mem.Allocator, io: Io, mode: config.Mode, configuration: *const config.Config, client: *http.Client, database: *sqlite.Database, preferred_node: ?[]const u8) ![]u8 {
    if (mode == .standalone) return listLocal(allocator, io, configuration, database);
    var target = (try harness_nodes.selectCapability(allocator, io, database, "terminal", preferred_node)) orelse return error.ProjectNodeRequired;
    defer target.deinit();
    return node_transport.get(allocator, client, &target, "/internal/node/v1/projects") catch |failure| switch (failure) {
        error.NodeUnavailable => error.ProjectNodeUnavailable,
        else => failure,
    };
}

pub fn addPayload(allocator: std.mem.Allocator, io: Io, mode: config.Mode, configuration: *const config.Config, client: *http.Client, database: *sqlite.Database, preferred_node: ?[]const u8, document: []const u8) ![]u8 {
    if (mode == .standalone) return addLocal(allocator, io, configuration, database, document);
    var target = (try harness_nodes.selectCapability(allocator, io, database, "terminal", preferred_node)) orelse return error.ProjectNodeRequired;
    defer target.deinit();
    return node_transport.send(allocator, client, &target, "/internal/node/v1/projects", .POST, document) catch |failure| switch (failure) {
        error.NodeRequestRejected => error.ProjectNodeRejected,
        else => failure,
    };
}

pub fn deletePayload(allocator: std.mem.Allocator, io: Io, mode: config.Mode, client: *http.Client, database: *sqlite.Database, preferred_node: ?[]const u8, id: []const u8) ![]u8 {
    try validateProjectId(id);
    if (mode == .standalone) return deleteLocal(allocator, io, database, id);
    var target = (try harness_nodes.selectCapability(allocator, io, database, "terminal", preferred_node)) orelse return error.ProjectNodeRequired;
    defer target.deinit();
    const path = try std.fmt.allocPrint(allocator, "/internal/node/v1/projects?id={s}", .{id});
    defer allocator.free(path);
    return node_transport.send(allocator, client, &target, path, .DELETE, null) catch |failure| switch (failure) {
        error.NodeRequestRejected => error.ProjectNodeRejected,
        else => failure,
    };
}

pub fn listLocal(allocator: std.mem.Allocator, io: Io, configuration: *const config.Config, database: *sqlite.Database) ![]u8 {
    const chats_path = try chatsPath(allocator, io, configuration.environment);
    defer allocator.free(chats_path);
    try database.lock(io);
    var projects = repository.list(allocator, database) catch |failure| {
        database.unlock(io);
        return failure;
    };
    database.unlock(io);
    defer projects.deinit();
    var output: Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"projects\":[");
    try writeProject(&output.writer, io, chats_id, "Chats", chats_path, "1970-01-01T00:00:00.000Z");
    for (projects.projects) |project| {
        try output.writer.writeByte(',');
        try writeProject(&output.writer, io, project.id, project.name, project.path, project.added_at);
    }
    try output.writer.writeAll("]}");
    return output.toOwnedSlice();
}

pub fn addLocal(allocator: std.mem.Allocator, io: Io, configuration: *const config.Config, database: *sqlite.Database, document: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, document, .{}) catch return error.InvalidProjectPayload;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidProjectPayload;
    const path_value = parsed.value.object.get("path") orelse return error.ProjectPathRequired;
    if (path_value != .string) return error.ProjectPathRequired;
    const canonical = try resolveAllowedPath(allocator, io, configuration.environment, path_value.string);
    defer allocator.free(canonical);
    try database.lock(io);
    defer database.unlock(io);
    if (try repository.getByPath(allocator, database, canonical)) |existing_value| {
        var existing = existing_value;
        defer existing.deinit();
        return projectEnvelope(allocator, io, &existing);
    }
    var random: [12]u8 = undefined;
    io.random(&random);
    const encoded = std.fmt.bytesToHex(random, .lower);
    const id = try std.fmt.allocPrint(allocator, "proj-{s}", .{encoded[0..]});
    defer allocator.free(id);
    const name = std.fs.path.basename(canonical);
    var timestamp_buffer: [24]u8 = undefined;
    const added_at = formatTimestamp(io, &timestamp_buffer);
    try repository.save(database, id, name, canonical, added_at);
    const project = repository.Project{ .allocator = allocator, .id = try allocator.dupe(u8, id), .name = try allocator.dupe(u8, name), .path = try allocator.dupe(u8, canonical), .added_at = try allocator.dupe(u8, added_at) };
    var mutable = project;
    defer mutable.deinit();
    return projectEnvelope(allocator, io, &mutable);
}

pub fn deleteLocal(allocator: std.mem.Allocator, io: Io, database: *sqlite.Database, id: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, id, " \t\r\n");
    try validateProjectId(trimmed);
    if (!std.mem.eql(u8, trimmed, chats_id)) {
        try database.lock(io);
        defer database.unlock(io);
        try repository.delete(database, trimmed);
    }
    return allocator.dupe(u8, "{\"ok\":true}");
}

fn projectEnvelope(allocator: std.mem.Allocator, io: Io, project: *const repository.Project) ![]u8 {
    var output: Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"project\":");
    try writeProject(&output.writer, io, project.id, project.name, project.path, project.added_at);
    try output.writer.writeByte('}');
    return output.toOwnedSlice();
}

fn writeProject(writer: *Io.Writer, io: Io, id: []const u8, name: []const u8, path: []const u8, added_at: []const u8) !void {
    const stat = Io.Dir.cwd().statFile(io, path, .{}) catch null;
    const exists = if (stat) |value| value.kind == .directory else false;
    const git_path = try std.fs.path.join(std.heap.page_allocator, &.{ path, ".git" });
    defer std.heap.page_allocator.free(git_path);
    const has_git = if (Io.Dir.cwd().statFile(io, git_path, .{})) |_| true else |_| false;
    const branch = if (has_git) try gitBranch(std.heap.page_allocator, io, path) else null;
    defer if (branch) |value| std.heap.page_allocator.free(value);
    try writer.writeAll("{\"id\":");
    try std.json.Stringify.value(id, .{}, writer);
    try writer.writeAll(",\"name\":");
    try std.json.Stringify.value(name, .{}, writer);
    try writer.writeAll(",\"path\":");
    try std.json.Stringify.value(path, .{}, writer);
    try writer.writeAll(",\"addedAt\":");
    try std.json.Stringify.value(added_at, .{}, writer);
    try writer.print(",\"exists\":{},\"hasGit\":{},\"branch\":", .{ exists, has_git });
    if (branch) |value| try std.json.Stringify.value(value, .{}, writer) else try writer.writeAll("null");
    try writer.writeByte('}');
}

fn gitBranch(allocator: std.mem.Allocator, io: Io, path: []const u8) !?[]u8 {
    const head_path = try std.fs.path.join(allocator, &.{ path, ".git", "HEAD" });
    defer allocator.free(head_path);
    const document = Io.Dir.cwd().readFileAlloc(io, head_path, allocator, .limited(4096)) catch return null;
    defer allocator.free(document);
    const line = std.mem.trim(u8, std.mem.sliceTo(document, '\n'), " \t\r\n");
    const prefix = "ref: refs/heads/";
    if (std.mem.startsWith(u8, line, prefix) and line.len > prefix.len) return @as(?[]u8, try allocator.dupe(u8, line[prefix.len..]));
    if (line.len >= 7) return @as(?[]u8, try allocator.dupe(u8, line[0..7]));
    return null;
}

fn chatsPath(allocator: std.mem.Allocator, io: Io, environment: *const std.process.Environ.Map) ![]u8 {
    const home = environment.get("HOME") orelse return error.HomeDirectoryUnavailable;
    const path = try std.fs.path.join(allocator, &.{ home, ".local-studio" });
    errdefer allocator.free(path);
    _ = try Io.Dir.cwd().createDirPathStatus(io, path, @enumFromInt(0o700));
    return path;
}

fn resolveAllowedPath(allocator: std.mem.Allocator, io: Io, environment: *const std.process.Environ.Map, raw: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return error.ProjectPathRequired;
    if (!std.fs.path.isAbsolute(trimmed)) return error.ProjectPathMustBeAbsolute;
    const canonical = Io.Dir.realPathFileAbsoluteAlloc(io, trimmed, allocator) catch return error.ProjectPathNotFound;
    errdefer allocator.free(canonical);
    const stat = Io.Dir.cwd().statFile(io, canonical, .{}) catch return error.ProjectPathNotFound;
    if (stat.kind != .directory) return error.ProjectPathNotDirectory;
    const configured = environment.get("WORKSPACE_ROOTS") orelse environment.get("HOME") orelse return error.HomeDirectoryUnavailable;
    var roots = std.mem.splitScalar(u8, configured, std.fs.path.delimiter);
    while (roots.next()) |root_value| {
        const root_trimmed = std.mem.trim(u8, root_value, " \t\r\n");
        if (root_trimmed.len == 0 or !std.fs.path.isAbsolute(root_trimmed)) continue;
        const root = Io.Dir.realPathFileAbsoluteAlloc(io, root_trimmed, allocator) catch continue;
        defer allocator.free(root);
        if (withinRoot(root, canonical)) return canonical;
    }
    return error.ProjectPathOutsideRoots;
}

fn withinRoot(root: []const u8, candidate: []const u8) bool {
    if (std.mem.eql(u8, root, candidate)) return true;
    if (!std.mem.startsWith(u8, candidate, root) or candidate.len <= root.len) return false;
    return candidate[root.len] == std.fs.path.sep;
}

fn validateProjectId(id: []const u8) !void {
    if (id.len == 0) return error.ProjectIdRequired;
    if (id.len > 128) return error.InvalidProjectId;
    for (id) |character| if (!std.ascii.isAlphanumeric(character) and character != '-' and character != '_') return error.InvalidProjectId;
}

fn formatTimestamp(io: Io, buffer: *[24]u8) []const u8 {
    const seconds = Io.Clock.real.now(io).toSeconds();
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(seconds, 0)) };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.000Z", .{ year_day.year, month_day.month.numeric(), month_day.day_index + 1, day_seconds.getHoursIntoDay(), day_seconds.getMinutesIntoHour(), day_seconds.getSecondsIntoMinute() }) catch unreachable;
}
