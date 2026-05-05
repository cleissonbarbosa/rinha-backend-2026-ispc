const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_arch = .x86_64,
            .os_tag = .linux,
        },
    });
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseFast,
    });
    const ispc_object = b.option([]const u8, "ispc-object", "Path to a compiled ISPC object file");
    const enable_profiler = b.option(bool, "enable_profiler", "Compile runtime profiler instrumentation") orelse false;

    const build_options = b.addOptions();
    build_options.addOption(bool, "use_ispc", ispc_object != null);
    build_options.addOption(bool, "enable_profiler", enable_profiler);

    const exe = b.addExecutable(.{
        .name = "rinha-server",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addOptions("build_options", build_options);
    if (ispc_object) |path| {
        exe.addObjectFile(.{ .cwd_relative = path });
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the server");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests.root_module.addOptions("build_options", build_options);
    if (ispc_object) |path| {
        tests.addObjectFile(.{ .cwd_relative = path });
    }

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
