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
    const fx_build_options = b.addOptions();
    fx_build_options.addOption([]const u8, "git_commit", "669ef8a7f0bf6b13a1722bfd434fb9fc61d01511");
    fx_build_options.addOption([]const u8, "app_version", "0.0.0-local-studio");
    fx_build_options.addOption([]const u8, "update_channel", "stable");
    fx_build_options.addOption(bool, "local_studio_mcp_only", true);
    const fx_module = b.createModule(.{
        .root_source_file = b.path("fx_local_studio.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    fx_module.addImport("build_options", fx_build_options.createModule());
    root_module.addImport("fx", fx_module);
    const model_index_document = b.build_root.handle.readFileAlloc(b.graph.io, "../controller/contracts/model-index.json", b.allocator, .limited(4 * 1024 * 1024)) catch @panic("unable to read model index contract");
    const model_index_options = b.addOptions();
    model_index_options.addOption([]const u8, "document", model_index_document);
    root_module.addOptions("model_index_contract", model_index_options);
    const model_catalog_document = b.build_root.handle.readFileAlloc(b.graph.io, "../controller/contracts/model-catalog.json", b.allocator, .limited(4 * 1024 * 1024)) catch @panic("unable to read model catalog contract");
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
