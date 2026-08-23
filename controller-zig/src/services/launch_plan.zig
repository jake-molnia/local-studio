const std = @import("std");
const builtin = @import("builtin");

pub const EnvironmentEntry = struct {
    key: []const u8,
    value: []const u8,
};

pub const Plan = struct {
    arena: std.heap.ArenaAllocator,
    recipe_id: []const u8,
    backend: []const u8,
    port: u16,
    argv: []const []const u8,
    environment: []const EnvironmentEntry,
    health_path: []const u8,
    ready_timeout_seconds: u64,

    pub fn deinit(plan: *Plan) void {
        plan.arena.deinit();
        plan.* = undefined;
    }
};

pub fn build(allocator: std.mem.Allocator, document: []const u8) !Plan {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const storage = try arena.allocator().dupe(u8, document);
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), storage, .{}) catch return error.InvalidRecipe;
    if (value != .object) return error.InvalidRecipe;
    const object = value.object;
    const recipe_id = stringField(object, "id") orelse return error.InvalidRecipe;
    const backend = stringField(object, "backend") orelse return error.InvalidRecipe;
    const model_path = stringField(object, "model_path") orelse return error.InvalidRecipe;
    const served_name = nullableStringField(object, "served_model_name") orelse model_path;
    const port = portField(object, "port") orelse return error.InvalidRecipe;
    const runtime_value = object.get("runtime") orelse return error.InvalidRecipe;
    if (runtime_value != .object) return error.InvalidRecipe;
    const runtime_kind = stringField(runtime_value.object, "kind") orelse return error.InvalidRecipe;
    const runtime_ref = stringField(runtime_value.object, "ref") orelse return error.InvalidRecipe;
    if (std.mem.eql(u8, runtime_kind, "docker")) return error.DockerRuntimeNotImplemented;
    try validateHostSupport(backend);

    const binary = if (std.mem.eql(u8, runtime_kind, "binary") or std.mem.eql(u8, runtime_kind, "system"))
        runtime_ref
    else
        defaultBinary(backend) orelse return error.UnsupportedBackend;

    var extra: std.ArrayList([]const u8) = .empty;
    var overridden: std.StringHashMapUnmanaged(void) = .empty;
    if (object.get("extra_args")) |extra_value| {
        if (extra_value != .object) return error.InvalidRecipe;
        var iterator = extra_value.object.iterator();
        while (iterator.next()) |entry| {
            const key = try normalizedKey(arena.allocator(), entry.key_ptr.*);
            if (internalKey(key) or forbiddenKey(backend, key)) continue;
            switch (entry.value_ptr.*) {
                .null => {},
                .bool => |enabled| if (enabled) {
                    try extra.append(arena.allocator(), try flag(arena.allocator(), key));
                    try overridden.put(arena.allocator(), key, {});
                },
                .string => |text| {
                    try extra.append(arena.allocator(), try flag(arena.allocator(), key));
                    try extra.append(arena.allocator(), text);
                    try overridden.put(arena.allocator(), key, {});
                },
                .integer => |number| {
                    try extra.append(arena.allocator(), try flag(arena.allocator(), key));
                    try extra.append(arena.allocator(), try std.fmt.allocPrint(arena.allocator(), "{d}", .{number}));
                    try overridden.put(arena.allocator(), key, {});
                },
                .float => |number| {
                    try extra.append(arena.allocator(), try flag(arena.allocator(), key));
                    try extra.append(arena.allocator(), try std.fmt.allocPrint(arena.allocator(), "{d}", .{number}));
                    try overridden.put(arena.allocator(), key, {});
                },
                .number_string => |number| {
                    try extra.append(arena.allocator(), try flag(arena.allocator(), key));
                    try extra.append(arena.allocator(), number);
                    try overridden.put(arena.allocator(), key, {});
                },
                .array, .object => {
                    var output: std.Io.Writer.Allocating = .init(arena.allocator());
                    try std.json.Stringify.value(entry.value_ptr.*, .{}, &output.writer);
                    try extra.append(arena.allocator(), try flag(arena.allocator(), key));
                    try extra.append(arena.allocator(), try output.toOwnedSlice());
                    try overridden.put(arena.allocator(), key, {});
                },
            }
        }
    }

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena.allocator(), binary);
    if (std.mem.eql(u8, backend, "vllm")) try argv.append(arena.allocator(), "serve");
    if (std.mem.eql(u8, backend, "sglang")) try argv.append(arena.allocator(), "serve");
    if (std.mem.eql(u8, backend, "vllm")) {
        try argv.append(arena.allocator(), model_path);
        try appendPair(&argv, arena.allocator(), &overridden, "served-model-name", served_name);
    } else if (std.mem.eql(u8, backend, "sglang")) {
        try appendPair(&argv, arena.allocator(), &overridden, "model-path", model_path);
        try appendPair(&argv, arena.allocator(), &overridden, "served-model-name", served_name);
    } else if (std.mem.eql(u8, backend, "llamacpp")) {
        try appendPair(&argv, arena.allocator(), &overridden, "model", model_path);
        try appendPair(&argv, arena.allocator(), &overridden, "alias", served_name);
    } else if (std.mem.eql(u8, backend, "mlx")) {
        try appendPair(&argv, arena.allocator(), &overridden, "model", model_path);
    } else return error.UnsupportedBackend;

    try appendPair(&argv, arena.allocator(), &overridden, "host", "127.0.0.1");
    try appendPair(&argv, arena.allocator(), &overridden, "port", try std.fmt.allocPrint(arena.allocator(), "{d}", .{port}));
    try appendTuning(&argv, arena.allocator(), &overridden, object, backend);
    if (std.mem.eql(u8, backend, "sglang")) try appendFlag(&argv, arena.allocator(), &overridden, "enable-metrics");
    if (std.mem.eql(u8, backend, "llamacpp")) try appendFlag(&argv, arena.allocator(), &overridden, "metrics");
    try argv.appendSlice(arena.allocator(), extra.items);

    var environment: std.ArrayList(EnvironmentEntry) = .empty;
    if (object.get("env_vars")) |env_value| {
        if (env_value != .null) {
            if (env_value != .object) return error.InvalidRecipe;
            var iterator = env_value.object.iterator();
            while (iterator.next()) |entry| {
                if (entry.value_ptr.* != .string) return error.InvalidRecipe;
                try environment.append(arena.allocator(), .{ .key = entry.key_ptr.*, .value = entry.value_ptr.string });
            }
        }
    }

    return .{
        .arena = arena,
        .recipe_id = recipe_id,
        .backend = backend,
        .port = port,
        .argv = try argv.toOwnedSlice(arena.allocator()),
        .environment = try environment.toOwnedSlice(arena.allocator()),
        .health_path = if (std.mem.eql(u8, backend, "mlx")) "/v1/models" else "/health",
        .ready_timeout_seconds = if (std.mem.eql(u8, backend, "vllm")) 1800 else if (std.mem.eql(u8, backend, "sglang")) 900 else if (std.mem.eql(u8, backend, "llamacpp")) 600 else 300,
    };
}

fn appendTuning(argv: *std.ArrayList([]const u8), allocator: std.mem.Allocator, overridden: *const std.StringHashMapUnmanaged(void), object: std.json.ObjectMap, backend: []const u8) !void {
    if (std.mem.eql(u8, backend, "vllm") or std.mem.eql(u8, backend, "sglang")) {
        try appendInteger(argv, allocator, overridden, if (std.mem.eql(u8, backend, "vllm")) "tensor-parallel-size" else "tensor-parallel-size", object.get("tensor_parallel_size"), true);
        try appendInteger(argv, allocator, overridden, "pipeline-parallel-size", object.get("pipeline_parallel_size"), true);
        try appendInteger(argv, allocator, overridden, if (std.mem.eql(u8, backend, "vllm")) "max-model-len" else "context-length", object.get("max_model_len"), false);
        try appendNumber(argv, allocator, overridden, if (std.mem.eql(u8, backend, "vllm")) "gpu-memory-utilization" else "mem-fraction-static", object.get("gpu_memory_utilization"));
        try appendInteger(argv, allocator, overridden, if (std.mem.eql(u8, backend, "vllm")) "max-num-seqs" else "max-running-requests", object.get("max_num_seqs"), false);
        try appendOptionalString(argv, allocator, overridden, "kv-cache-dtype", object.get("kv_cache_dtype"), true);
        try appendOptionalString(argv, allocator, overridden, "dtype", object.get("dtype"), false);
        try appendOptionalString(argv, allocator, overridden, "quantization", object.get("quantization"), false);
        if (booleanField(object, "trust_remote_code")) try appendFlag(argv, allocator, overridden, "trust-remote-code");
        if (object.get("tool_call_parser")) |value| if (value == .string) {
            try appendPair(argv, allocator, overridden, "tool-call-parser", value.string);
            if (std.mem.eql(u8, backend, "vllm")) try appendFlag(argv, allocator, overridden, "enable-auto-tool-choice");
        };
        try appendOptionalString(argv, allocator, overridden, "reasoning-parser", object.get("reasoning_parser"), false);
        return;
    }
    if (std.mem.eql(u8, backend, "llamacpp")) {
        try appendInteger(argv, allocator, overridden, "ctx-size", object.get("max_model_len"), false);
        try appendInteger(argv, allocator, overridden, "parallel", object.get("max_num_seqs"), false);
        return;
    }
    if (std.mem.eql(u8, backend, "mlx")) {
        try appendInteger(argv, allocator, overridden, "max-tokens", object.get("max_model_len"), false);
        if (booleanField(object, "trust_remote_code")) try appendFlag(argv, allocator, overridden, "trust-remote-code");
    }
}

fn appendInteger(argv: *std.ArrayList([]const u8), allocator: std.mem.Allocator, overridden: *const std.StringHashMapUnmanaged(void), key: []const u8, value: ?std.json.Value, parallel: bool) !void {
    const present = value orelse return;
    if (present != .integer or present.integer <= 0 or (parallel and present.integer <= 1)) return;
    try appendPair(argv, allocator, overridden, key, try std.fmt.allocPrint(allocator, "{d}", .{present.integer}));
}

fn appendNumber(argv: *std.ArrayList([]const u8), allocator: std.mem.Allocator, overridden: *const std.StringHashMapUnmanaged(void), key: []const u8, value: ?std.json.Value) !void {
    const present = value orelse return;
    const text = switch (present) {
        .integer => |number| try std.fmt.allocPrint(allocator, "{d}", .{number}),
        .float => |number| try std.fmt.allocPrint(allocator, "{d}", .{number}),
        .number_string => |number| number,
        else => return,
    };
    try appendPair(argv, allocator, overridden, key, text);
}

fn appendOptionalString(argv: *std.ArrayList([]const u8), allocator: std.mem.Allocator, overridden: *const std.StringHashMapUnmanaged(void), key: []const u8, value: ?std.json.Value, skip_auto: bool) !void {
    const present = value orelse return;
    if (present != .string or present.string.len == 0 or (skip_auto and std.mem.eql(u8, present.string, "auto"))) return;
    try appendPair(argv, allocator, overridden, key, present.string);
}

fn appendPair(argv: *std.ArrayList([]const u8), allocator: std.mem.Allocator, overridden: *const std.StringHashMapUnmanaged(void), key: []const u8, value: []const u8) !void {
    if (overridden.contains(key)) return;
    try argv.append(allocator, try flag(allocator, key));
    try argv.append(allocator, value);
}

fn appendFlag(argv: *std.ArrayList([]const u8), allocator: std.mem.Allocator, overridden: *const std.StringHashMapUnmanaged(void), key: []const u8) !void {
    if (!overridden.contains(key)) try argv.append(allocator, try flag(allocator, key));
}

fn flag(allocator: std.mem.Allocator, key: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "--{s}", .{key});
}

fn normalizedKey(allocator: std.mem.Allocator, key: []const u8) ![]const u8 {
    const output = try allocator.alloc(u8, key.len);
    for (key, output) |character, *target| target.* = if (character == '_') '-' else std.ascii.toLower(character);
    return output;
}

fn internalKey(key: []const u8) bool {
    for ([_][]const u8{ "visible-devices", "cuda-visible-devices", "hip-visible-devices", "rocr-visible-devices", "venv-path", "env-vars", "description", "tags", "status", "metadata", "llama-bin", "mlx-python", "launch-command", "custom-command", "docker-container", "docker-image" }) |internal| {
        if (std.mem.eql(u8, key, internal)) return true;
    }
    return false;
}

fn forbiddenKey(backend: []const u8, key: []const u8) bool {
    if (!std.mem.eql(u8, backend, "vllm") and !std.mem.eql(u8, backend, "sglang")) return false;
    return compactKeyEquals(key, "disablecudagraphs") or compactKeyEquals(key, "enforceeager") or compactKeyEquals(key, "maxtokens");
}

fn compactKeyEquals(key: []const u8, expected: []const u8) bool {
    var index: usize = 0;
    for (key) |character| {
        if (character == '-' or character == '_' or std.ascii.isWhitespace(character)) continue;
        if (index >= expected.len or std.ascii.toLower(character) != expected[index]) return false;
        index += 1;
    }
    return index == expected.len;
}

fn defaultBinary(backend: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, backend, "vllm")) return "vllm";
    if (std.mem.eql(u8, backend, "sglang")) return "sglang";
    if (std.mem.eql(u8, backend, "llamacpp")) return "llama-server";
    if (std.mem.eql(u8, backend, "mlx")) return "mlx_lm.server";
    return null;
}

fn validateHostSupport(backend: []const u8) !void {
    if (std.mem.eql(u8, backend, "mlx") and (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64)) return error.UnsupportedPlatform;
    if ((std.mem.eql(u8, backend, "vllm") or std.mem.eql(u8, backend, "sglang")) and builtin.os.tag == .macos) return error.UnsupportedPlatform;
    if (defaultBinary(backend) == null) return error.UnsupportedBackend;
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return if (value == .string and value.string.len > 0) value.string else null;
}

fn nullableStringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return if (value == .string and value.string.len > 0) value.string else null;
}

fn booleanField(object: std.json.ObjectMap, name: []const u8) bool {
    const value = object.get(name) orelse return false;
    return value == .bool and value.bool;
}

fn portField(object: std.json.ObjectMap, name: []const u8) ?u16 {
    const value = object.get(name) orelse return null;
    if (value != .integer or value.integer <= 0 or value.integer > std.math.maxInt(u16)) return null;
    return @intCast(value.integer);
}
