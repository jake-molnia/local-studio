const std = @import("std");

pub const github_url = "https://api.githubcopilot.com/mcp/";

const EnvironmentField = struct {
    key: []const u8,
    label: []const u8,
    placeholder: ?[]const u8 = null,
    secret: bool,
};

const Entry = struct {
    id: []const u8,
    name: []const u8,
    company: []const u8,
    description: []const u8,
    protocol_era: []const u8 = "modern",
    transport: []const u8 = "stdio",
    command: ?[]const u8 = "{{LOCAL_STUDIO_CONTROLLER}}",
    args: []const []const u8 = &.{},
    state: []const u8 = "remote",
    filesystem_access: bool = false,
    recommended: bool = true,
    installable: bool = true,
    required_configuration: []const []const u8 = &.{},
    env_fields: []const EnvironmentField = &.{},
    auth_provider: ?[]const u8 = null,
    unavailable_reason: ?[]const u8 = null,
};

const bearer = [_]EnvironmentField{.{ .key = "MCP_AUTHORIZATION", .label = "Authorization header", .placeholder = "Bearer …", .secret = true }};

const entries = [_]Entry{
    .{
        .id = "browser",
        .name = "Browser",
        .company = "Local Studio",
        .description = "Bundled Chromium navigation, interaction, screenshots, network inspection, and readable web fetches",
        .transport = "builtin",
        .command = null,
        .state = "controller-owned",
        .installable = false,
    },
    .{
        .id = "github",
        .name = "GitHub",
        .company = "GitHub",
        .description = "Repositories, code search, issues, pull requests, releases, and Actions through GitHub's official remote MCP",
        .args = &.{ "mcp-forward", github_url, "auto" },
        .required_configuration = &.{"oauth"},
        .auth_provider = "github",
    },
    remote("notion", "Notion", "Notion", "Workspace search, pages, databases, comments, and content", "https://mcp.notion.com/mcp", "auto", true),
    remote("linear", "Linear", "Linear", "Issues, projects, cycles, initiatives, comments, and workspace search", "https://mcp.linear.app/mcp", "auto", true),
    remote("atlassian", "Atlassian Rovo", "Atlassian", "Jira and Confluence search, issues, projects, pages, and comments", "https://mcp.atlassian.com/v1/mcp/authv2", "auto", true),
    remote("cloudflare", "Cloudflare API", "Cloudflare", "Search and execute across the Cloudflare API", "https://mcp.cloudflare.com/mcp", "modern", true),
    remote("cloudflare-docs", "Cloudflare Documentation", "Cloudflare", "Search current Cloudflare product and developer documentation", "https://docs.mcp.cloudflare.com/mcp", "modern", false),
    remote("cloudflare-bindings", "Cloudflare Bindings", "Cloudflare", "Build Workers applications with Cloudflare bindings and resources", "https://bindings.mcp.cloudflare.com/mcp", "modern", false),
    remote("cloudflare-builds", "Cloudflare Builds", "Cloudflare", "Inspect Workers builds and deployment failures", "https://builds.mcp.cloudflare.com/mcp", "modern", false),
    remote("cloudflare-observability", "Cloudflare Observability", "Cloudflare", "Inspect logs, traces, errors, and operational health", "https://observability.mcp.cloudflare.com/mcp", "modern", true),
    remote("cloudflare-radar", "Cloudflare Radar", "Cloudflare", "Query public Internet traffic, routing, security, and outage data", "https://radar.mcp.cloudflare.com/mcp", "modern", false),
    remote("vercel", "Vercel", "Vercel", "Projects, deployments, logs, domains, teams, and documentation", "https://mcp.vercel.com", "auto", true),
    remote("railway", "Railway", "Railway", "Projects, services, deployments, variables, logs, and infrastructure", "https://mcp.railway.com", "auto", true),
    remote("supabase", "Supabase", "Supabase", "Projects, databases, SQL, migrations, logs, and edge functions", "https://mcp.supabase.com/mcp", "auto", true),
    remote("stripe", "Stripe", "Stripe", "Customers, payments, subscriptions, products, invoices, and balance data", "https://mcp.stripe.com", "auto", true),
    remote("x-api", "X API", "X", "Search posts and users, inspect trends and news, and use app-authorized X API tools", "https://api.x.com/mcp", "auto", true),
    publicRemote("x-docs", "X Developer Documentation", "X", "Search and read current X API documentation, references, examples, and guides", "https://docs.x.com/mcp", "modern"),
    publicRemote("mcp-docs", "MCP Documentation", "Model Context Protocol", "Search the official Model Context Protocol specification and documentation", "https://modelcontextprotocol.io/mcp", "modern"),
    publicRemote("code-storage-docs", "Code.Storage Documentation", "The Pierre Computer Company", "Search and read Code.Storage documentation and submit documentation feedback", "https://code.storage/docs/mcp", "auto"),
    .{
        .id = "computer",
        .name = "Remote computer",
        .company = "Local Studio",
        .description = "Run commands and work with files over SSH on another machine",
        .protocol_era = "legacy",
        .args = &.{"mcp-ssh"},
        .state = "stateful",
        .filesystem_access = true,
        .required_configuration = &.{"SSH_HOST"},
        .env_fields = &.{.{ .key = "SSH_HOST", .label = "SSH host", .placeholder = "user@machine", .secret = false }},
    },
    accountEntry("code-storage", "Code.Storage", "Authenticated repositories, commits, refs, pushes, and remote agent handoff"),
    accountEntry("google-gmail", "Gmail", "Search, read, compose, label, and send mail through connected Google accounts"),
    accountEntry("google-drive", "Google Drive", "Search and read files through connected Google accounts"),
    accountEntry("google-calendar", "Google Calendar", "Read and manage calendars and events through connected Google accounts"),
    accountEntry("google-chat", "Google Chat", "Read spaces and send messages through connected Google accounts"),
    disabledLocal("filesystem", "Filesystem", "Restricted file operations within task-scoped roots"),
    disabledLocal("git", "Git", "Repository inspection and mutation within task-scoped roots"),
};

fn remote(comptime id: []const u8, comptime name: []const u8, comptime company: []const u8, comptime description: []const u8, comptime url: []const u8, comptime upstream_era: []const u8, comptime recommended: bool) Entry {
    return .{
        .id = id,
        .name = name,
        .company = company,
        .description = description,
        .args = &.{ "mcp-forward", url, upstream_era },
        .recommended = recommended,
        .required_configuration = &.{"authorization"},
        .env_fields = &bearer,
    };
}

fn publicRemote(comptime id: []const u8, comptime name: []const u8, comptime company: []const u8, comptime description: []const u8, comptime url: []const u8, comptime upstream_era: []const u8) Entry {
    return .{ .id = id, .name = name, .company = company, .description = description, .args = &.{ "mcp-forward", url, upstream_era }, .state = "stateless" };
}

fn accountEntry(comptime id: []const u8, comptime name: []const u8, comptime description: []const u8) Entry {
    return .{
        .id = id,
        .name = name,
        .company = "Local Studio",
        .description = description,
        .transport = "builtin",
        .command = null,
        .state = "account-managed",
        .installable = false,
        .unavailable_reason = "Connect an account from Settings to create one connector per account",
    };
}

fn disabledLocal(comptime id: []const u8, comptime name: []const u8, comptime description: []const u8) Entry {
    return .{
        .id = id,
        .name = name,
        .company = "Local Studio",
        .description = description,
        .transport = "builtin",
        .command = null,
        .state = "policy-disabled",
        .filesystem_access = true,
        .recommended = false,
        .installable = false,
        .unavailable_reason = "Filesystem-bound tools remain disabled until sandbox-backed task roots are active",
    };
}

pub fn write(writer: *std.Io.Writer) !void {
    try writer.writeAll("{\"source\":\"local-studio\",\"profile\":\"native-first-wave\",\"entries\":[");
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
    try writer.writeAll(",\"company\":");
    try std.json.Stringify.value(entry.company, .{}, writer);
    try writer.writeAll(",\"description\":");
    try std.json.Stringify.value(entry.description, .{}, writer);
    try writer.writeAll(",\"protocolEra\":");
    try std.json.Stringify.value(entry.protocol_era, .{}, writer);
    try writer.writeAll(",\"transport\":");
    try std.json.Stringify.value(entry.transport, .{}, writer);
    if (entry.command) |command| {
        try writer.writeAll(",\"command\":");
        try std.json.Stringify.value(command, .{}, writer);
    }
    if (entry.args.len > 0) {
        try writer.writeAll(",\"args\":[");
        for (entry.args, 0..) |argument, index| {
            if (index > 0) try writer.writeByte(',');
            try std.json.Stringify.value(argument, .{}, writer);
        }
        try writer.writeByte(']');
    }
    try writer.writeAll(",\"state\":");
    try std.json.Stringify.value(entry.state, .{}, writer);
    try writer.print(",\"filesystemAccess\":{},\"recommended\":{},\"installable\":{}", .{ entry.filesystem_access, entry.recommended, entry.installable });
    try writer.writeAll(",\"requiredConfiguration\":[");
    for (entry.required_configuration, 0..) |field, index| {
        if (index > 0) try writer.writeByte(',');
        try std.json.Stringify.value(field, .{}, writer);
    }
    try writer.writeAll("],\"envFields\":[");
    for (entry.env_fields, 0..) |field, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeAll("{\"key\":");
        try std.json.Stringify.value(field.key, .{}, writer);
        try writer.writeAll(",\"label\":");
        try std.json.Stringify.value(field.label, .{}, writer);
        if (field.placeholder) |placeholder| {
            try writer.writeAll(",\"placeholder\":");
            try std.json.Stringify.value(placeholder, .{}, writer);
        }
        try writer.print(",\"secret\":{}}}", .{field.secret});
    }
    try writer.writeByte(']');
    if (entry.auth_provider) |provider| {
        try writer.writeAll(",\"authProvider\":");
        try std.json.Stringify.value(provider, .{}, writer);
    }
    if (entry.unavailable_reason) |reason| {
        try writer.writeAll(",\"unavailableReason\":");
        try std.json.Stringify.value(reason, .{}, writer);
    }
    try writer.writeByte('}');
}
