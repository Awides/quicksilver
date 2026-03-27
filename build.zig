const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_module = b.createModule(.{
        .root_source_file = b.path("hades/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "hades",
        .root_module = root_module,
    });

    // zglfw dependency
    const zglfw_dep = b.dependency("zglfw", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("zglfw", zglfw_dep.module("root"));
    exe.linkLibrary(zglfw_dep.artifact("glfw"));

    // wgpu_native_zig dependency
    const wgpu_dep = b.dependency("wgpu_native_zig", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("wgpu", wgpu_dep.module("wgpu"));

    // msdf-zig dependency
    const msdf_dep = b.dependency("msdf_zig", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("msdf", msdf_dep.module("msdf-zig"));

    // Platform-specific system libraries
    const os_tag = target.result.os.tag;
    if (os_tag == .windows) {
        exe.addLibraryPath(.{ .cwd_relative = "/usr/x86_64-w64-mingw32/lib" });
        exe.linkSystemLibrary("user32");
        exe.linkSystemLibrary("gdi32");
        exe.linkSystemLibrary("opengl32");
        exe.linkSystemLibrary("oleaut32");
        exe.linkSystemLibrary("ole32");
        exe.linkSystemLibrary("ws2_32");
        exe.linkSystemLibrary("userenv");
        exe.linkSystemLibrary("propsys");
        exe.linkSystemLibrary("d3dcompiler_47");
        exe.linkSystemLibrary("dxgi");
        exe.linkSystemLibrary("d3d11");
        exe.linkSystemLibrary("kernel32");
    } else if (os_tag == .linux) {
        exe.linkSystemLibrary("x11");
        exe.linkSystemLibrary("xrandr");
        exe.linkSystemLibrary("xi");
        exe.linkSystemLibrary("dl");
        exe.linkSystemLibrary("pthread");
    }

    b.installArtifact(exe);
}
