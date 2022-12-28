const std = @import("std");
const zfetch = @import("deps/zfetch/build.zig");

pub fn build(b: *std.build.Builder) !void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();
    const exe = b.addExecutable("bkg", "src/main.zig");
    exe.setTarget(target);

    // Strip debug symbols by default
    // Should be disabled during development/debugging
    exe.strip = false;

    exe.linkLibC();

    // Link bOptimizer
    if(target.getOs().tag == .linux and target.getCpu().arch == .x86_64) {
        exe.addObjectFile("deps/bOptimizer/build/out/libboptimizer-x86_64-linux.a");
    }else if(target.getOs().tag == .linux and target.getCpu().arch == .aarch64) {
        exe.addObjectFile("deps/bOptimizer/build/out/libboptimizer-aarch64-linux.a");
    }else if(target.getOs().tag == .macos and target.getCpu().arch == .x86_64) {
        b.sysroot = "/home/theseyan/Go/bOptimizer/build/sdk-macos-12.0-main/root";
        exe.addLibraryPath("/home/theseyan/Go/bOptimizer/build/sdk-macos-12.0-main/root/usr/lib");
        exe.addFrameworkPath("/home/theseyan/Go/bOptimizer/build/sdk-macos-12.0-main/root/System/Library/Frameworks");
        exe.linkFramework("CoreFoundation");
        exe.addObjectFile("deps/bOptimizer/build/out/libboptimizer-x86_64-macos.a");
    }else if(target.getOs().tag == .macos and target.getCpu().arch == .aarch64) {
        exe.addObjectFile("deps/bOptimizer/build/out/libboptimizer-aarch64-macos.a");
    }

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
