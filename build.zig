const std = @import("std");
const zfetch = @import("deps/zfetch/build.zig");

pub fn build(b: *std.build.Builder) !void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();
    const exe = b.addExecutable("bkg", "src/main.zig");

    // Strip debug symbols by default
    // Should be disabled during development/debugging
    exe.strip = true;

    // Force stage1 compiler
    //exe.use_stage1 = true;

    exe.linkLibC();

    // Compile LZ4 library
    exe.addCSourceFile("deps/lz4/lib/lz4.c", &.{});
    exe.addCSourceFile("deps/lz4/lib/lz4hc.c", &.{});

    // Compile microtar library
    exe.addCSourceFile("deps/microtar/src/microtar.c", &.{});

    // Compile zip library
    exe.addCSourceFile("deps/zip/src/zip.c", &.{});

    // Link zig-clap library
    exe.addPackagePath("clap", "deps/zig-clap/clap.zig");

    // Link zfetch
    exe.addPackage(try zfetch.getPackage(b));

    // Link known-folders
    exe.addPackagePath("known-folders", "deps/known-folders/known-folders.zig");

    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    // Run step
    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
