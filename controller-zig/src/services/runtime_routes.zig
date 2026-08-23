const std = @import("std");
const config_module = @import("../config.zig");
const system_info = @import("../platform/system_info.zig");
const runtime_info = @import("runtime_info.zig");

pub const Backend = enum { vllm, sglang, llamacpp, mlx };

pub fn backendPayload(allocator: std.mem.Allocator, configuration: *const config_module.Config, system: *const system_info.Snapshot, cache: *runtime_info.Cache, backend: Backend) ![]u8 {
    const document = try cache.payload(allocator, configuration, system);
    defer allocator.free(document);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, document, .{}) catch return error.InvalidRuntimePayload;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidRuntimePayload;
    const backends = objectField(parsed.value.object, "backends") orelse return error.InvalidRuntimePayload;
    const value = backends.get(@tagName(backend)) orelse return error.InvalidRuntimePayload;
    if (value != .object) return error.InvalidRuntimePayload;
    if (backend != .vllm) return stringify(allocator, value);
    const Vllm = struct {
        installed: bool,
        version: ?[]const u8,
        python_path: ?[]const u8,
        vllm_bin: ?[]const u8,
        upgrade_command_available: bool,
        bundled_wheel: ?u8 = null,
    };
    return stringify(allocator, Vllm{
        .installed = boolean(value.object, "installed") orelse false,
        .version = optionalString(value.object, "version"),
        .python_path = optionalString(value.object, "python_path"),
        .vllm_bin = if (boolean(value.object, "installed") orelse false) optionalString(value.object, "binary_path") else null,
        .upgrade_command_available = boolean(value.object, "upgrade_command_available") orelse false,
    });
}

pub fn cudaPayload(allocator: std.mem.Allocator, configuration: *const config_module.Config, system: *const system_info.Snapshot, cache: *runtime_info.Cache) ![]u8 {
    return objectPayload(allocator, configuration, system, cache, "cuda");
}

pub fn rocmPayload(allocator: std.mem.Allocator, configuration: *const config_module.Config, system: *const system_info.Snapshot, cache: *runtime_info.Cache) ![]u8 {
    const document = try cache.payload(allocator, configuration, system);
    defer allocator.free(document);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, document, .{}) catch return error.InvalidRuntimePayload;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidRuntimePayload;
    const platform = objectField(parsed.value.object, "platform") orelse return error.InvalidRuntimePayload;
    const rocm = platform.get("rocm");
    if (rocm) |value| if (value == .object) return stringify(allocator, value);
    const Empty = struct {
        rocm_version: ?u8 = null,
        hip_version: ?u8 = null,
        smi_tool: ?u8 = null,
        gpu_arch: []const []const u8 = &.{},
        upgrade_command_available: bool = false,
    };
    return stringify(allocator, Empty{});
}

pub fn configHelpPayload(allocator: std.mem.Allocator, io: std.Io, configuration: *const config_module.Config, backend: Backend) ![]u8 {
    const command: []const u8 = switch (backend) {
        .vllm => "vllm",
        .llamacpp => configuration.llama_bin orelse "llama-server",
        else => return error.ConfigHelpUnavailable,
    };
    const arguments: []const []const u8 = switch (backend) {
        .vllm => &.{ command, "serve", "--help" },
        .llamacpp => &.{ command, "--help" },
        else => unreachable,
    };
    const result = std.process.run(allocator, io, .{
        .argv = arguments,
        .stdout_limit = .limited(4 * 1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .timeout = .{ .duration = .{ .clock = .awake, .raw = std.Io.Duration.fromSeconds(5) } },
    }) catch return configHelpResult(allocator, null, if (backend == .vllm) "vLLM runtime not available" else "llama.cpp runtime not available");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const success = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!success) {
        const config = nonempty(result.stdout);
        const message = nonempty(result.stderr) orelse if (backend == .vllm) "Failed to fetch vLLM config" else "Failed to fetch llama.cpp config";
        return configHelpResult(allocator, config, message);
    }
    return configHelpResult(allocator, nonempty(result.stdout) orelse nonempty(result.stderr), null);
}

fn objectPayload(allocator: std.mem.Allocator, configuration: *const config_module.Config, system: *const system_info.Snapshot, cache: *runtime_info.Cache, name: []const u8) ![]u8 {
    const document = try cache.payload(allocator, configuration, system);
    defer allocator.free(document);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, document, .{}) catch return error.InvalidRuntimePayload;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidRuntimePayload;
    const value = parsed.value.object.get(name) orelse return error.InvalidRuntimePayload;
    if (value != .object) return error.InvalidRuntimePayload;
    return stringify(allocator, value);
}

fn configHelpResult(allocator: std.mem.Allocator, config: ?[]const u8, message: ?[]const u8) ![]u8 {
    const Result = struct { config: ?[]const u8, @"error": ?[]const u8 };
    return stringify(allocator, Result{ .config = config, .@"error" = message });
}

fn stringify(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try std.json.Stringify.value(value, .{}, &output.writer);
    return output.toOwnedSlice();
}

fn objectField(object: std.json.ObjectMap, name: []const u8) ?std.json.ObjectMap {
    const value = object.get(name) orelse return null;
    return if (value == .object) value.object else null;
}

fn optionalString(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

fn boolean(object: std.json.ObjectMap, name: []const u8) ?bool {
    const value = object.get(name) orelse return null;
    return if (value == .bool) value.bool else null;
}

fn nonempty(value: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    return if (trimmed.len > 0) trimmed else null;
}
