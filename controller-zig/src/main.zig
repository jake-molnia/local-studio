const std = @import("std");
const app_module = @import("app.zig");
const config = @import("config.zig");
const mcp_ssh = @import("mcp_ssh.zig");
const fx = @import("fx");

pub fn main(init: std.process.Init) !void {
    var arguments = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer arguments.deinit();
    _ = arguments.skip();
    if (arguments.next()) |command| {
        if (std.mem.eql(u8, command, "mcp-ssh")) return mcp_ssh.run(init);
        if (std.mem.eql(u8, command, "fx-acp")) return fx.run(init);
    }
    var settings = try config.Config.load(init);
    errdefer settings.deinit();
    var app = try app_module.App.init(init.gpa, init.io, settings);
    defer app.deinit();
    try app.run();
}
