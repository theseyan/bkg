const std = @import("std");
const cli = @import("cli.zig");
const cURL = @import("translated/libcurl.zig");
const versionManager = @import("version_manager.zig");
const compiler = @import("compiler.zig");

// Allocator
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var arena = std.heap.ArenaAllocator.init(gpa.allocator());
var allocator = arena.allocator();

pub fn main() anyerror!void {
    
    // Free all memory for the program when main exits
    defer arena.deinit();

    // try versionManager.init(allocator);
    // _ = try versionManager.downloadBun(try versionManager.getLatestBunVersion(), "x86_64-linux");

    try cli.init();

    // // Build archive
    // try compiler.buildArchive(allocator, "/home/theseyan/.bun/bin/bun", "/home/theseyan/Zig/bkg/example");

    // // Compress and package archive into target executable
    // try compiler.compressArchive(allocator, "/home/theseyan/Zig/bkg/bkg_runtime");

    // // Extract archive
    // try runtime.extractArchive(allocator, target_exe, temp_dir);

    // // Launch Bun runtime
    // try runtime.execProcess(allocator, temp_dir);

}