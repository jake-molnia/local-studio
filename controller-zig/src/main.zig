const std = @import("std");
const app_module = @import("app.zig");
const config = @import("config.zig");

pub fn main(init: std.process.Init) !void {
    const settings = try config.Config.load(init);
    var app = try app_module.App.init(init.gpa, init.io, settings);
    defer app.deinit();
    try app.run();
}
