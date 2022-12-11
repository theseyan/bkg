// This program is compiled separately as the runtime for packaging
// It should only deal with running the packaged app

// To build the runtime & strip debug symbols:
// zig build-exe -Drelease-fast src/bkg_runtime.zig --strip -lc deps/lz4/lib/lz4.c deps/microtar/src/microtar.c --pkg-begin known-folders deps/known-folders/known-folders.zig --pkg-end

const std = @import("std");
const runtime = @import("runtime.zig");
const knownFolders = @import("known-folders");
const config = @import("config.zig");
const debug = @import("debug.zig");

// Using evented IO causes a bug in the Zig compiler
// https://github.com/ziglang/zig/issues/11985
// pub const io_mode = .evented;

var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
var allocator = arena.allocator();

pub fn main() !void {

    // De-initialize allocator when main exits
    defer arena.deinit();

    // Get path to this binary
    var selfPath = try std.fs.selfExePathAlloc(allocator);
    var basename = std.fs.path.basename(selfPath);

    // Parse executable headers
    const headers = try runtime.parseBinary(allocator, selfPath);

    // We run the app in /tmp directory
    var runtimeDir = "/tmp";

    // App directory is formatted as: .{basename}_runtime_{hash}
    // where hash is the CRC32 hash of LZ4 compressed sources buffer
    var appDirPath = try std.mem.concat(allocator, u8, &.{runtimeDir, "/.", basename, "_runtime_", headers.hash});

    var appDir: ?void = std.fs.makeDirAbsolute(appDirPath) catch |e| switch(e) {
        error.PathAlreadyExists => null,
        else => return error.FailedToCreateAppDir,
    };

    if(appDir != null) {
        // Directory was created
        try runtime.extractArchive(allocator, selfPath, appDirPath, headers);
    }else {
        // Directory already exists, load configuration
        try config.load(allocator, try std.mem.concat(allocator, u8, &.{appDirPath, "/bkg.config.json"}), null);
        if(config.get().debug) debug.debug = true;

        if(debug.debug) {
            debug.print("Debug logs are enabled", .{});
            debug.print("Configuration file loaded from disk!", .{});
            debug.print("App directory already exists, skipping extraction..", .{});
        }
    }

    if(debug.debug) {
        debug.print("CRC32 Hash:\t{s}", .{headers.hash});
        debug.print("Compressed Size:\t{any} bytes", .{headers.compressed});
        debug.print("Starting Bun runtime..", .{});
    }

    // Execute process
    try runtime.execProcess(allocator, appDirPath, config.get());

}