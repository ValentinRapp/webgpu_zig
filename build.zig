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

    if (target.result.os.tag == .windows) {
        exe.addLibraryPath(.{ .cwd_relative = "C:/msys64/mingw64/lib" });
        exe.addIncludePath(.{ .cwd_relative = "C:/msys64/mingw64/include" });

        exe.linkSystemLibrary("glfw3");
        exe.linkSystemLibrary("gdi32");

        exe.linkSystemLibrary("wgpu_native");

        const install_dll = b.addInstallBinFile(
            .{ .cwd_relative = "C:/msys64/mingw64/bin/wgpu_native.dll" },
            "wgpu_native.dll"
        );
        b.getInstallStep().dependOn(&install_dll.step);
    } else if (target.result.os.tag == .macos) {
        exe.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
        exe.root_module.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
        exe.root_module.linkSystemLibrary("glfw", .{});
        exe.root_module.linkFramework("Cocoa", .{});
        exe.root_module.linkSystemLibrary("wgpu_native", .{});
    } else if (target.result.os.tag == .linux) {
        exe.root_module.linkSystemLibrary("glfw", .{});
        exe.root_module.linkSystemLibrary("wgpu_native", .{});

        // X11
        exe.root_module.linkSystemLibrary("X11", .{});
        exe.root_module.linkSystemLibrary("Xcursor", .{});
        exe.root_module.linkSystemLibrary("Xrandr", .{});
        exe.root_module.linkSystemLibrary("Xi", .{});

        // Wayland
        exe.root_module.linkSystemLibrary("wayland-client", .{});
    } else {
        @panic("Unsupported OS (only Windows, macOS, and Linux are supported)");
    }
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
