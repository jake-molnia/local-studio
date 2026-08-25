const std = @import("std");
const app_module = @import("app.zig");
const config = @import("config.zig");
const mcp_ssh = @import("mcp_ssh.zig");
const mcp_bridge = @import("mcp_bridge.zig");
const mcp_code_storage = @import("mcp_code_storage.zig");
const fx = @import("fx");

pub fn main(init: std.process.Init) !void {
    var arguments = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer arguments.deinit();
    _ = arguments.skip();
    if (arguments.next()) |command| {
        if (std.mem.eql(u8, command, "mcp-ssh")) return mcp_ssh.run(init);
        if (std.mem.eql(u8, command, "mcp-bridge")) return mcp_bridge.run(init);
        if (std.mem.eql(u8, command, "mcp-code-storage")) return mcp_code_storage.run(init);
        if (std.mem.eql(u8, command, "chat-runtime")) return fx.runChat(init);
    }
    var settings = try config.Config.load(init);
    errdefer settings.deinit();
    var app = try app_module.App.init(init.gpa, init.io, settings);
    defer app.deinit();
    try app.run();
}
