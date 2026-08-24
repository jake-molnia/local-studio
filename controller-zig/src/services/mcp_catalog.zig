const std = @import("std");

const Entry = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    protocol_era: []const u8,
    transport: []const u8,
    runtime_kind: ?[]const u8 = null,
    package: ?[]const u8 = null,
    version: ?[]const u8 = null,
    executable: ?[]const u8 = null,
    url: ?[]const u8 = null,
    state: []const u8,
    filesystem_access: bool,
    recommended: bool,
    required_configuration: []const []const u8 = &.{},
};

const entries = [_]Entry{
    .{
        .id = "mcp-docs",
        .name = "MCP Documentation",
        .description = "Official Model Context Protocol documentation search",
        .protocol_era = "modern",
        .transport = "http",
        .url = "https://modelcontextprotocol.io/mcp",
        .state = "stateless",
        .filesystem_access = false,
        .recommended = true,
    },
    .{
        .id = "mcp-fetch",
        .name = "Fetch",
        .description = "Fetches web content and converts it for model consumption",
        .protocol_era = "legacy",
        .transport = "stdio",
        .runtime_kind = "python",
        .package = "mcp-server-fetch",
        .version = "2026.7.10",
        .executable = "mcp-server-fetch",
        .state = "stateless",
        .filesystem_access = false,
        .recommended = true,
    },
    .{
        .id = "mcp-time",
        .name = "Time",
        .description = "Timezone lookup and conversion",
        .protocol_era = "legacy",
        .transport = "stdio",
        .runtime_kind = "python",
        .package = "mcp-server-time",
        .version = "2026.7.10",
        .executable = "mcp-server-time",
        .state = "stateless",
        .filesystem_access = false,
        .recommended = true,
    },
    .{
        .id = "mcp-sequential-thinking",
        .name = "Sequential Thinking",
        .description = "Structured dynamic problem solving",
        .protocol_era = "legacy",
        .transport = "stdio",
        .runtime_kind = "node",
        .package = "@modelcontextprotocol/server-sequential-thinking",
        .version = "2026.7.4",
        .executable = "mcp-server-sequential-thinking",
        .state = "stateless",
        .filesystem_access = false,
        .recommended = true,
    },
    .{
        .id = "mcp-memory",
        .name = "Memory",
        .description = "Persistent knowledge graph memory",
        .protocol_era = "legacy",
        .transport = "stdio",
        .runtime_kind = "node",
        .package = "@modelcontextprotocol/server-memory",
        .version = "2026.7.4",
        .executable = "mcp-server-memory",
        .state = "stateful",
        .filesystem_access = false,
        .recommended = true,
    },
    .{
        .id = "mcp-everything",
        .name = "Everything",
        .description = "Reference server covering protocol features",
        .protocol_era = "legacy",
        .transport = "stdio",
        .runtime_kind = "node",
        .package = "@modelcontextprotocol/server-everything",
        .version = "2026.7.4",
        .executable = "mcp-server-everything",
        .state = "stateless",
        .filesystem_access = false,
        .recommended = false,
    },
    .{
        .id = "mcp-filesystem",
        .name = "Filesystem",
        .description = "Restricted file operations within explicitly supplied roots",
        .protocol_era = "legacy",
        .transport = "stdio",
        .runtime_kind = "node",
        .package = "@modelcontextprotocol/server-filesystem",
        .version = "2026.7.10",
        .executable = "mcp-server-filesystem",
        .state = "stateful",
        .filesystem_access = true,
        .recommended = false,
        .required_configuration = &.{"roots"},
    },
    .{
        .id = "mcp-git",
        .name = "Git",
        .description = "Repository inspection and mutation for an explicitly supplied repository",
        .protocol_era = "legacy",
        .transport = "stdio",
        .runtime_kind = "python",
        .package = "mcp-server-git",
        .version = "2026.7.10",
        .executable = "mcp-server-git",
        .state = "stateful",
        .filesystem_access = true,
        .recommended = false,
        .required_configuration = &.{"repository"},
    },
};

pub fn write(writer: *std.Io.Writer) !void {
    try writer.writeAll("{\"source\":\"modelcontextprotocol-reference\",\"profile\":\"mcp-only\",\"entries\":[");
    for (entries, 0..) |entry, index| {
        if (index > 0) try writer.writeByte(',');
        try writeEntry(writer, entry);
    }
    try writer.writeAll("]}");
}

fn writeEntry(writer: *std.Io.Writer, entry: Entry) !void {
    try writer.writeAll("{\"id\":");
    try std.json.Stringify.value(entry.id, .{}, writer);
    try writer.writeAll(",\"name\":");
    try std.json.Stringify.value(entry.name, .{}, writer);
    try writer.writeAll(",\"description\":");
    try std.json.Stringify.value(entry.description, .{}, writer);
    try writer.writeAll(",\"protocolEra\":");
    try std.json.Stringify.value(entry.protocol_era, .{}, writer);
    try writer.writeAll(",\"transport\":");
    try std.json.Stringify.value(entry.transport, .{}, writer);
    if (entry.runtime_kind) |kind| {
        try writer.writeAll(",\"runtime\":{\"kind\":");
        try std.json.Stringify.value(kind, .{}, writer);
        try writer.writeAll(",\"package\":");
        try std.json.Stringify.value(entry.package.?, .{}, writer);
        try writer.writeAll(",\"version\":");
        try std.json.Stringify.value(entry.version.?, .{}, writer);
        try writer.writeAll(",\"executable\":");
        try std.json.Stringify.value(entry.executable.?, .{}, writer);
        try writer.writeByte('}');
    }
    if (entry.url) |url| {
        try writer.writeAll(",\"url\":");
        try std.json.Stringify.value(url, .{}, writer);
    }
    try writer.writeAll(",\"state\":");
    try std.json.Stringify.value(entry.state, .{}, writer);
    try writer.print(",\"filesystemAccess\":{},\"recommended\":{}", .{ entry.filesystem_access, entry.recommended });
    try writer.writeAll(",\"requiredConfiguration\":[");
    for (entry.required_configuration, 0..) |field, index| {
        if (index > 0) try writer.writeByte(',');
        try std.json.Stringify.value(field, .{}, writer);
    }
    try writer.writeAll("]}");
}
