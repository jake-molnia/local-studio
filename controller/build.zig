const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const chat_build_options = b.addOptions();
    chat_build_options.addOption([]const u8, "git_commit", "669ef8a7f0bf6b13a1722bfd434fb9fc61d01511");
    chat_build_options.addOption([]const u8, "app_version", "0.0.0-local-studio");
    chat_build_options.addOption([]const u8, "update_channel", "stable");
    chat_build_options.addOption(bool, "local_studio_mcp_only", true);
    const chat_module = b.createModule(.{
        .root_source_file = b.path("../chat/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const mcp_bridge_module = b.createModule(.{
        .root_source_file = b.path("src/agent/mcp/bridge.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    chat_module.addImport("build_options", chat_build_options.createModule());
    chat_module.addImport("mcp_bridge", mcp_bridge_module);
    root_module.addImport("chat", chat_module);
    root_module.addImport("mcp_bridge", mcp_bridge_module);
    const model_index_document = b.build_root.handle.readFileAlloc(b.graph.io, "../contracts/model-index.json", b.allocator, .limited(4 * 1024 * 1024)) catch @panic("unable to read model index contract");
    const model_index_options = b.addOptions();
    model_index_options.addOption([]const u8, "document", model_index_document);
    root_module.addOptions("model_index_contract", model_index_options);
    const model_catalog_document = b.build_root.handle.readFileAlloc(b.graph.io, "../contracts/model-catalog.json", b.allocator, .limited(4 * 1024 * 1024)) catch @panic("unable to read model catalog contract");
    const model_catalog_options = b.addOptions();
    model_catalog_options.addOption([]const u8, "document", model_catalog_document);
    root_module.addOptions("model_catalog_contract", model_catalog_options);
    const executable = b.addExecutable(.{
        .name = "local-studio-controller",
        .root_module = root_module,
    });
    b.installArtifact(executable);

    const run_command = b.addRunArtifact(executable);
    run_command.step.dependOn(b.getInstallStep());
    if (b.args) |arguments| run_command.addArgs(arguments);

    const run_step = b.step("run", "Run the controller");
    run_step.dependOn(&run_command.step);
}
