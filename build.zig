const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const wgpu = b.dependency("wgpu_native", .{
        .target = target,
        .optimize = optimize,
    });

    const zglfw = b.dependency("zglfw", .{
        .target = target,
        .optimize = optimize,
    });

    const zm = b.dependency("zm", .{
        .target = target,
        .optimize = optimize,
    });

    const zstbi = b.dependency("zstbi", .{
        .target = target,
        .optimize = optimize,
    });

    const obj_mod = b.dependency("obj", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "webgpu_zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "webgpu", .module = wgpu.module("webgpu") },
                .{ .name = "glfw", .module = zglfw.module("glfw") },
                .{ .name = "zm", .module = zm.module("zm") },
                .{ .name = "zstbi", .module = zstbi.module("root") },
                .{ .name = "obj", .module = obj_mod.module("obj") },
            },
        }),
    });

    // Link GLFW library
    exe.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    exe.root_module.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    exe.root_module.linkSystemLibrary("glfw", .{});
    exe.root_module.linkFramework("Cocoa", .{});
    exe.root_module.linkFramework("IOKit", .{});
    exe.root_module.linkFramework("CoreFoundation", .{});
    exe.root_module.linkFramework("QuartzCore", .{});
    exe.root_module.linkFramework("Metal", .{});

    // Link wgpu-native library
    exe.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    exe.root_module.linkSystemLibrary("wgpu_native", .{});

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
