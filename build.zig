const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();
    const exe = b.addExecutable("bkg", "src/main.zig");

    exe.linkLibC();

    // Link LZ4 library
    exe.addCSourceFile("deps/lz4/lib/lz4.c", &.{});

    // Link microtar library
    exe.addCSourceFile("deps/microtar/src/microtar.c", &.{});

    // Link zig-clap library
    exe.addPackagePath("clap", "deps/zig-clap/clap.zig");

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
