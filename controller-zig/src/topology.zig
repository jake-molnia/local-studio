const config = @import("config.zig");
const route_registry = @import("route_registry.zig");

pub const Disposition = enum {
    local,
    proxy,
    reject,
};

pub fn disposition(mode: config.Mode, ownership: route_registry.Ownership) Disposition {
    return switch (mode) {
        .head => switch (ownership) {
            .shared, .head => .local,
            .proxied => .proxy,
            .worker => .reject,
        },
        .worker => switch (ownership) {
            .shared, .worker, .proxied => .local,
            .head => .reject,
        },
        .standalone => .local,
    };
}
