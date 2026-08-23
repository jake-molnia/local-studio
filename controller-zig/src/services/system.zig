const std = @import("std");
const config_module = @import("../config.zig");
const system_info = @import("../platform/system_info.zig");
const lifecycle = @import("lifecycle.zig");
const runtime_info = @import("runtime_info.zig");

const Io = std.Io;

pub fn configPayload(allocator: std.mem.Allocator, io: Io, config: *const config_module.Config, system: *const system_info.Snapshot, supervisor: *lifecycle.Supervisor, runtime_cache: *runtime_info.Cache) ![]u8 {
    const runtime = try runtime_cache.payload(allocator, config, system);
    defer allocator.free(runtime);
    const inference_running = try supervisor.isRunning();
    const frontend_running = serviceReachable(io, 3000);
    const Service = struct {
        name: []const u8,
        port: u16,
        internal_port: u16,
        protocol: []const u8 = "http",
        status: []const u8,
        description: []const u8,
    };
    const services = [_]Service{
        .{
            .name = "Controller",
            .port = config.port,
            .internal_port = config.port,
            .status = "running",
            .description = "Controller service (Zig)",
        },
        .{
            .name = "Inference runtime",
            .port = config.inference_port,
            .internal_port = config.inference_port,
            .status = if (inference_running) "running" else "stopped",
            .description = "Inference backend (vLLM, SGLang, llama.cpp, or MLX)",
        },
        .{
            .name = "Frontend",
            .port = 3000,
            .internal_port = 3000,
            .status = if (frontend_running) "running" else "stopped",
            .description = "Next.js web UI",
        },
    };
    const Payload = struct {
        config: struct {
            controller_mode: []const u8,
            host: []const u8,
            port: u16,
            inference_port: u16,
            api_key_configured: bool,
            models_dir: []const u8,
            data_dir: []const u8,
            db_path: []const u8,
            sglang_python: ?[]const u8,
            llama_bin: ?[]const u8,
            mlx_python: ?[]const u8,
        },
        services: []const Service,
        environment: struct {
            controller_url: []const u8,
            inference_url: []const u8,
            frontend_url: []const u8,
        },
    };
    const controller_url = try std.fmt.allocPrint(allocator, "http://{s}:{d}", .{ system.hostname, config.port });
    defer allocator.free(controller_url);
    const inference_url = try std.fmt.allocPrint(allocator, "http://{s}:{d}", .{ system.hostname, config.inference_port });
    defer allocator.free(inference_url);
    const frontend_url = try std.fmt.allocPrint(allocator, "http://{s}:3000", .{system.hostname});
    defer allocator.free(frontend_url);
    var base: Io.Writer.Allocating = .init(allocator);
    defer base.deinit();
    try std.json.Stringify.value(Payload{
        .config = .{
            .controller_mode = @tagName(config.mode),
            .host = config.host,
            .port = config.port,
            .inference_port = config.inference_port,
            .api_key_configured = config.api_key != null,
            .models_dir = config.models_dir,
            .data_dir = config.data_dir,
            .db_path = config.db_path,
            .sglang_python = config.sglang_python,
            .llama_bin = config.llama_bin,
            .mlx_python = config.mlx_python,
        },
        .services = &services,
        .environment = .{
            .controller_url = controller_url,
            .inference_url = inference_url,
            .frontend_url = frontend_url,
        },
    }, .{}, &base.writer);
    const base_document = base.writer.buffered();
    if (base_document.len == 0 or base_document[base_document.len - 1] != '}') return error.InvalidSystemPayload;
    var output: Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll(base_document[0 .. base_document.len - 1]);
    try output.writer.writeAll(",\"runtime\":");
    try output.writer.writeAll(runtime);
    try output.writer.writeByte('}');
    return try output.toOwnedSlice();
}

pub fn compatibilityPayload(allocator: std.mem.Allocator, io: Io, config: *const config_module.Config, system: *const system_info.Snapshot, supervisor: *lifecycle.Supervisor, runtime_cache: *runtime_info.Cache) ![]u8 {
    const runtime_document = try runtime_cache.payload(allocator, config, system);
    defer allocator.free(runtime_document);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const storage = arena.allocator();
    const runtime = std.json.parseFromSliceLeaky(std.json.Value, storage, runtime_document, .{}) catch return error.InvalidRuntimePayload;
    if (runtime != .object) return error.InvalidRuntimePayload;
    const platform = objectField(runtime.object, "platform") orelse return error.InvalidRuntimePayload;
    const kind = stringField(platform, "kind") orelse return error.InvalidRuntimePayload;
    const gpu_monitoring_value = runtime.object.get("gpu_monitoring") orelse return error.InvalidRuntimePayload;
    const backends_value = runtime.object.get("backends") orelse return error.InvalidRuntimePayload;
    const gpus = objectField(runtime.object, "gpus") orelse return error.InvalidRuntimePayload;
    const torch_value = platform.get("torch") orelse return error.InvalidRuntimePayload;
    if (gpu_monitoring_value != .object or backends_value != .object or torch_value != .object) return error.InvalidRuntimePayload;

    const Check = struct {
        id: []const u8,
        severity: []const u8,
        message: []const u8,
        evidence: ?[]const u8,
        suggested_fix: ?[]const u8,
    };
    var checks: std.ArrayList(Check) = .empty;
    const gpu_count = unsignedField(gpus, "count") orelse 0;
    if (gpu_count == 0) {
        try checks.append(storage, .{
            .id = "gpu.none-detected",
            .severity = "warn",
            .message = "No GPUs detected by the controller.",
            .evidence = try std.fmt.allocPrint(storage, "platform.kind={s}\ngpus.count=0", .{kind}),
            .suggested_fix = if (std.mem.eql(u8, kind, "cuda"))
                "Verify NVIDIA drivers are installed and nvidia-smi is accessible."
            else if (std.mem.eql(u8, kind, "rocm"))
                "Verify ROCm is installed and GPU tools are available (amd-smi/rocm-smi)."
            else
                "Verify GPU drivers are installed and set LOCAL_STUDIO_GPU_SMI_TOOL if needed.",
        });
    }
    const monitoring_available = boolField(gpu_monitoring_value.object, "available");
    if (std.mem.eql(u8, kind, "cuda") and !monitoring_available) {
        try checks.append(storage, .{
            .id = "gpu-monitoring.cuda-unavailable",
            .severity = "warn",
            .message = "CUDA platform detected, but nvidia-smi is not accessible (GPU telemetry may be unavailable).",
            .evidence = "tool=nvidia-smi",
            .suggested_fix = "Ensure NVIDIA drivers are installed and nvidia-smi is on PATH.",
        });
    }
    if (std.mem.eql(u8, kind, "rocm") and !monitoring_available) {
        try checks.append(storage, .{
            .id = "gpu-monitoring.rocm-unavailable",
            .severity = "warn",
            .message = "ROCm platform detected, but GPU monitoring tooling is not accessible.",
            .evidence = null,
            .suggested_fix = "Ensure amd-smi or rocm-smi is installed and on PATH.",
        });
    }
    const known_process = try supervisor.isRunning();
    if (serviceReachable(io, config.inference_port) and !known_process) {
        try checks.append(storage, .{
            .id = "inference.port-in-use",
            .severity = "error",
            .message = "Inference port is in use by an unknown process.",
            .evidence = try std.fmt.allocPrint(storage, "inference_port={d}", .{config.inference_port}),
            .suggested_fix = "Stop the process using the inference port, or change LOCAL_STUDIO_INFERENCE_PORT to a free port.",
        });
    }
    var any_backend = false;
    var backend_iterator = backends_value.object.iterator();
    while (backend_iterator.next()) |entry| {
        if (entry.value_ptr.* == .object and boolField(entry.value_ptr.object, "installed")) any_backend = true;
    }
    if (!any_backend) {
        try checks.append(storage, .{
            .id = "backends.none-installed",
            .severity = "info",
            .message = "No inference runtime backends appear to be installed.",
            .evidence = null,
            .suggested_fix = "Install at least one backend runtime (vLLM, SGLang, llama.cpp, or MLX), then restart the controller.",
        });
    }
    const Payload = struct {
        platform: struct { kind: []const u8 },
        gpu_monitoring: std.json.Value,
        torch: std.json.Value,
        backends: std.json.Value,
        checks: []const Check,
    };
    var output: Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try std.json.Stringify.value(Payload{
        .platform = .{ .kind = kind },
        .gpu_monitoring = gpu_monitoring_value,
        .torch = torch_value,
        .backends = backends_value,
        .checks = checks.items,
    }, .{}, &output.writer);
    return try output.toOwnedSlice();
}

fn serviceReachable(io: Io, port: u16) bool {
    const address = std.Io.net.IpAddress.parse("127.0.0.1", port) catch return false;
    var stream = address.connect(io, .{ .mode = .stream }) catch return false;
    stream.close(io);
    return true;
}

fn objectField(object: std.json.ObjectMap, name: []const u8) ?std.json.ObjectMap {
    const value = object.get(name) orelse return null;
    return if (value == .object) value.object else null;
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return if (value == .string and value.string.len > 0) value.string else null;
}

fn unsignedField(object: std.json.ObjectMap, name: []const u8) ?u64 {
    const value = object.get(name) orelse return null;
    if (value != .integer or value.integer < 0) return null;
    return @intCast(value.integer);
}

fn boolField(object: std.json.ObjectMap, name: []const u8) bool {
    const value = object.get(name) orelse return false;
    return value == .bool and value.bool;
}
