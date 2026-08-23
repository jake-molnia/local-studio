const std = @import("std");
const system_info = @import("../platform/system_info.zig");

const Io = std.Io;

const Gpu = struct {
    id: ?[]const u8 = null,
    uuid: ?[]const u8 = null,
    pci_bus_id: ?[]const u8 = null,
    index: usize,
    name: []const u8,
    memory_total_mb: u64,
    memory_used_mb: u64,
    memory_free_mb: u64,
    utilization_pct: f64,
    temp_c: f64,
    power_draw: f64,
    power_limit: f64,
    memory_shared: bool = false,
    memory_usage_available: bool = true,
    utilization_available: bool = true,
    temperature_available: bool = true,
    power_available: bool = true,
};

pub fn gpuPayload(allocator: std.mem.Allocator, io: Io, system: *const system_info.Snapshot) ![]u8 {
    if (system.apple_silicon) return applePayload(allocator, system);
    return nvidiaPayload(allocator, io);
}

fn applePayload(allocator: std.mem.Allocator, system: *const system_info.Snapshot) ![]u8 {
    const name = try std.fmt.allocPrint(allocator, "{s} GPU", .{system.cpu_model orelse "Apple Silicon"});
    defer allocator.free(name);
    const memory_mb = system.memory_total_bytes / (1024 * 1024);
    const gpus = [_]Gpu{.{
        .id = "apple-metal-0",
        .index = 0,
        .name = name,
        .memory_total_mb = memory_mb,
        .memory_used_mb = 0,
        .memory_free_mb = memory_mb,
        .utilization_pct = 0,
        .temp_c = 0,
        .power_draw = 0,
        .power_limit = 0,
        .memory_shared = true,
        .memory_usage_available = false,
        .utilization_available = false,
        .temperature_available = false,
        .power_available = false,
    }};
    return stringifyPayload(allocator, &gpus);
}

fn nvidiaPayload(allocator: std.mem.Allocator, io: Io) ![]u8 {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "nvidia-smi", "--query-gpu=uuid,pci.bus_id,name,memory.total,memory.used,memory.free,utilization.gpu,temperature.gpu,power.draw,power.limit", "--format=csv,noheader,nounits" },
        .stdout_limit = .limited(4 * 1024 * 1024),
        .stderr_limit = .limited(64 * 1024),
        .timeout = .{ .duration = .{ .clock = .awake, .raw = Io.Duration.fromSeconds(5) } },
    }) catch return stringifyPayload(allocator, &.{});
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return stringifyPayload(allocator, &.{}),
        else => return stringifyPayload(allocator, &.{}),
    }
    var gpus: std.ArrayList(Gpu) = .empty;
    defer gpus.deinit(allocator);
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        var fields: [10][]const u8 = undefined;
        var parts = std.mem.splitScalar(u8, line, ',');
        var field_index: usize = 0;
        while (parts.next()) |part| {
            if (field_index >= fields.len) break;
            fields[field_index] = std.mem.trim(u8, part, " \t\r");
            field_index += 1;
        }
        if (field_index != fields.len) continue;
        try gpus.append(allocator, .{
            .uuid = identity(fields[0]),
            .pci_bus_id = identity(fields[1]),
            .index = gpus.items.len,
            .name = if (fields[2].len > 0) fields[2] else "Unknown",
            .memory_total_mb = megabytes(fields[3]),
            .memory_used_mb = megabytes(fields[4]),
            .memory_free_mb = megabytes(fields[5]),
            .utilization_pct = number(fields[6]),
            .temp_c = number(fields[7]),
            .power_draw = number(fields[8]),
            .power_limit = number(fields[9]),
        });
    }
    return stringifyPayload(allocator, gpus.items);
}

fn stringifyPayload(allocator: std.mem.Allocator, gpus: []const Gpu) ![]u8 {
    const Payload = struct {
        count: usize,
        gpus: []const Gpu,
    };
    var output: Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try std.json.Stringify.value(Payload{ .count = gpus.len, .gpus = gpus }, .{}, &output.writer);
    return try output.toOwnedSlice();
}

fn identity(value: []const u8) ?[]const u8 {
    if (value.len == 0 or std.ascii.eqlIgnoreCase(value, "N/A") or std.ascii.eqlIgnoreCase(value, "[Not Supported]")) return null;
    return value;
}

fn number(value: []const u8) f64 {
    return std.fmt.parseFloat(f64, value) catch 0;
}

fn megabytes(value: []const u8) u64 {
    const parsed = number(value);
    if (parsed <= 0) return 0;
    return @intFromFloat(@round(parsed));
}
