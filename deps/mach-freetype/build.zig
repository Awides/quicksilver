const std = @import("std");

pub fn build(b: *std.Build) void {
    const freetype_module = b.addModule("mach-freetype", .{
        .root_source_file = b.path("src/freetype.zig"),
    });
    const harfbuzz_module = b.addModule("mach-harfbuzz", .{
        .root_source_file = b.path("src/harfbuzz.zig"),
        .imports = &.{.{ .name = "freetype", .module = freetype_module }},
    });

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const use_system_zlib = b.option(bool, "use_system_zlib", "Use system zlib") orelse false;
    const enable_brotli = b.option(bool, "enable_brotli", "Build brotli") orelse true;

    if (b.lazyDependency("freetype", .{
        .target = target,
        .optimize = optimize,
        .use_system_zlib = use_system_zlib,
        .enable_brotli = enable_brotli,
    })) |dep| {
        freetype_module.linkLibrary(dep.artifact("freetype"));
        harfbuzz_module.linkLibrary(dep.artifact("freetype"));
    }
    if (b.lazyDependency("harfbuzz", .{
        .target = target,
        .optimize = optimize,
        .enable_freetype = true,
        .freetype_use_system_zlib = use_system_zlib,
        .freetype_enable_brotli = enable_brotli,
    })) |dep| {
        harfbuzz_module.linkLibrary(dep.artifact("harfbuzz"));
    }
}
