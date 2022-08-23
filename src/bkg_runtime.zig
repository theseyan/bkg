// This program is compiled separately as the runtime for packaging
// It should only deal with running the packaged app

// To build the runtime & strip debug symbols:
// zig build-exe -Drelease-fast src/bkg_runtime.zig --strip -lc deps/lz4/lib/lz4.c deps/microtar/src/microtar.c --pkg-begin known-folders deps/known-folders/known-folders.zig --pkg-end

const std = @import("std");
const runtime = @import("runtime.zig");
const knownFolders = @import("known-folders");
const config = @import("config.zig");

var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
var allocator = arena.allocator();

pub fn main() !void {

    // De-initialize allocator when main exits
    defer arena.deinit();

    // Get path to this binary
    var selfPath = try allocator.alloc(u8, 300);
    selfPath = try std.fs.selfExePath(selfPath);
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
    }

    // Load configuration file
    try config.load(allocator, try std.mem.concat(allocator, u8, &.{appDirPath, "/bkg.config.json"}));

    // Execute process
    try runtime.execProcess(allocator, appDirPath, config.get());

}