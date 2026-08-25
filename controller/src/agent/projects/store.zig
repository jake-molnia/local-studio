const std = @import("std");
const sqlite = @import("../../storage/sqlite.zig");

pub const Project = struct {
    allocator: std.mem.Allocator,
    id: []u8,
    name: []u8,
    path: []u8,
    added_at: []u8,

    pub fn deinit(project: *Project) void {
        project.allocator.free(project.id);
        project.allocator.free(project.name);
        project.allocator.free(project.path);
        project.allocator.free(project.added_at);
        project.* = undefined;
    }
};

pub const List = struct {
    allocator: std.mem.Allocator,
    projects: []Project,

    pub fn deinit(project_list: *List) void {
        for (project_list.projects) |*project| project.deinit();
        project_list.allocator.free(project_list.projects);
        project_list.* = undefined;
    }
};

pub fn initialize(database: *sqlite.Database) !void {
    try database.executeScript(
        \\CREATE TABLE IF NOT EXISTS agent_projects (
        \\  project_id TEXT PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  path TEXT NOT NULL UNIQUE,
        \\  added_at TEXT NOT NULL,
        \\  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        \\);
        \\CREATE INDEX IF NOT EXISTS idx_agent_projects_added ON agent_projects(added_at DESC);
    );
}

pub fn list(allocator: std.mem.Allocator, database: *sqlite.Database) !List {
    var projects: std.ArrayList(Project) = .empty;
    errdefer {
        for (projects.items) |*project| project.deinit();
        projects.deinit(allocator);
    }
    var statement = try database.prepare("SELECT project_id, name, path, added_at FROM agent_projects ORDER BY added_at DESC LIMIT 10000");
    defer statement.deinit();
    while (try statement.step() == .row) try projects.append(allocator, try readProject(allocator, &statement));
    return .{ .allocator = allocator, .projects = try projects.toOwnedSlice(allocator) };
}

pub fn getByPath(allocator: std.mem.Allocator, database: *sqlite.Database, path: []const u8) !?Project {
    var statement = try database.prepare("SELECT project_id, name, path, added_at FROM agent_projects WHERE path = ?");
    defer statement.deinit();
    try statement.bindText(1, path);
    if (try statement.step() != .row) return null;
    return try readProject(allocator, &statement);
}

pub fn save(database: *sqlite.Database, id: []const u8, name: []const u8, path: []const u8, added_at: []const u8) !void {
    var statement = try database.prepare("INSERT INTO agent_projects (project_id, name, path, added_at) VALUES (?, ?, ?, ?)");
    defer statement.deinit();
    try statement.bindText(1, id);
    try statement.bindText(2, name);
    try statement.bindText(3, path);
    try statement.bindText(4, added_at);
    if (try statement.step() != .done) return error.DatabaseUnexpectedRow;
}

pub fn delete(database: *sqlite.Database, id: []const u8) !void {
    var statement = try database.prepare("DELETE FROM agent_projects WHERE project_id = ?");
    defer statement.deinit();
    try statement.bindText(1, id);
    if (try statement.step() != .done) return error.DatabaseUnexpectedRow;
}

fn readProject(allocator: std.mem.Allocator, statement: *sqlite.Statement) !Project {
    const id = try allocator.dupe(u8, statement.columnText(0) orelse return error.InvalidProjectRecord);
    errdefer allocator.free(id);
    const name = try allocator.dupe(u8, statement.columnText(1) orelse return error.InvalidProjectRecord);
    errdefer allocator.free(name);
    const path = try allocator.dupe(u8, statement.columnText(2) orelse return error.InvalidProjectRecord);
    errdefer allocator.free(path);
    return .{
        .allocator = allocator,
        .id = id,
        .name = name,
        .path = path,
        .added_at = try allocator.dupe(u8, statement.columnText(3) orelse return error.InvalidProjectRecord),
    };
}
