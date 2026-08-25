const std = @import("std");

pub const filesystem_tools_enabled = false;

pub fn allows(name: []const u8, browser_enabled: bool) bool {
    if (std.mem.startsWith(u8, name, "browser_")) return browser_enabled;
    for ([_][]const u8{ "computer__", "mcp-filesystem__", "mcp-git__", "filesystem__", "file__", "git__", "shell__", "terminal__", "ssh__" }) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) return false;
    }
    return true;
}
