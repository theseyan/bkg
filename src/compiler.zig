// Archives source files into TAR and compresses with LZ4
const std = @import("std");
const lz4 = @import("translated/liblz4.zig");
const mtar = @import("translated/libmicrotar.zig");

// Builds a TAR archive given a root directory
pub fn buildArchive(allocator: std.mem.Allocator, bun_path: []const u8, root: []const u8) anyerror!void {
    
    std.debug.print("Building archive...\n", .{});

    // TAR reference
    var tar: mtar.mtar_t = undefined;

    // Open archive for writing
    _ = mtar.mtar_open(&tar, "__bkg_build.tar", "w");
    defer _ = mtar.mtar_close(&tar);

    // Recursively search for files
    var dir = try std.fs.openDirAbsolute(root, .{ .iterate = true });
    defer dir.close();
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    // Add sources to archive
    while (try walker.next()) |entry| {
        // Handle directories
        if(entry.kind == .Directory) {
            std.debug.print("Writing directory {s}\n", .{entry.path});
            _ = mtar.mtar_write_dir_header(&tar, (try allocator.dupe(u8, entry.path)).ptr);
            continue;
        }

        // Read source into buffer
        var file = try std.fs.openFileAbsolute(try std.mem.concat(allocator, u8, &.{root, "/", entry.path}), .{});
        const buf: []u8 = try file.readToEndAlloc(allocator, 1024 * 1024 * 1024);

        std.debug.print("Writing file {s} with {} bytes\n", .{entry.path, buf.len});

        // Write buffer to archive
        _ = mtar.mtar_write_file_header(&tar, (try allocator.dupe(u8, entry.path)).ptr, @intCast(c_uint, buf.len));
        _ = mtar.mtar_write_data(&tar, buf.ptr, @intCast(c_uint, buf.len));

        // Close & free memory for this file
        allocator.free(buf);
        file.close();
    }
    
    // Add Bun binary to archive
    {
        var bun = try std.fs.openFileAbsolute(bun_path, .{});
        const bunBuf: []u8 = try bun.readToEndAlloc(allocator, 256 * 1024 * 1024);

        std.debug.print("Adding Bun binary...\n", .{});
        _ = mtar.mtar_write_file_header(&tar, "bkg_bun", @intCast(c_uint, bunBuf.len));
        _ = mtar.mtar_write_data(&tar, bunBuf.ptr, @intCast(c_uint, bunBuf.len));

        allocator.free(bunBuf);
        bun.close();
    }

    // Finalize the archive
    _ = mtar.mtar_finalize(&tar);

    std.debug.print("Finalized archive\n", .{});

}

// Applies LZ4 compression on given TAR archive
pub fn compressArchive(allocator: std.mem.Allocator, target: []const u8) anyerror!void {
    
    std.debug.print("Compressing archive...\n", .{});

    // Open archive and read it's contents
    var archive = try std.fs.cwd().openFile("__bkg_build.tar", .{});
    defer archive.close();
    const buf: []u8 = try archive.readToEndAlloc(allocator, 1024 * 1024 * 1024); // We assume the archive is < 1 GiB
    defer allocator.free(buf);

    // Delete temporary archive file
    try std.fs.cwd().deleteFile("__bkg_build.tar");

    // Allocate 256 MiB buffer for storing compressed archive
    var compressed: []u8 = try allocator.alloc(u8, 1024 * 1024 * 256);
    defer allocator.free(compressed);

    // Perform LZ4 compression
    var compSize = lz4.LZ4_compress_default(buf.ptr, compressed.ptr, @intCast(c_int, buf.len), 1024 * 1024 * 256);

    std.debug.print("Compressed to {} bytes\n", .{compSize});

    var file = try std.fs.openFileAbsolute(target, .{.mode = .read_write});
    defer file.close();

    // Seek to end of binary
    var stat = try file.stat();
    try file.seekTo(stat.size);

    std.debug.print("Writing archive to binary...\n", .{});

    // Write compressed archive to binary
    var written = try file.write(compressed[0..@intCast(usize, compSize)]);
    std.debug.print("Written {} bytes to binary\n", .{written});

    // Write compressed size at the end (10 bytes)
    {
        std.debug.print("Finalizing binary...\n", .{});
        var compSizeBuffer: []u8 = try allocator.alloc(u8, 10);
        defer allocator.free(compSizeBuffer);
        var compSizeBufferStream = std.io.fixedBufferStream(compSizeBuffer);
        try std.fmt.format(compSizeBufferStream.writer(), "{}", .{compSize});

        _ = try file.write(compSizeBuffer);
    }
    std.debug.print("Done\n", .{});

}

// TODO: Stream tar buffer directly to lz4 in memory
// Will reduce a few syscalls, and make compiling considerably faster

// Allocate a 200 MiB buffer for the stream
// var tarBuffer = try allocator.alloc(u8, 200 * 1024 * 1024);
// //defer allocator.free(tarBuffer);
// var tar: *mtar.mtar_t = try allocator.create(mtar.mtar_t);
// //defer allocator.destroy(tar);
// // TAR archive
// tar.* = mtar.mtar_t{
//     .write = writeCallback,
//     .stream = &tarBuffer,
//     .read = null,
//     .seek = null,
//     .close = null,
//     .pos = 0,
//     .last_header = 0,
//     .remaining_data = 0,
// };
// pub fn writeCallback(tar: [*c]mtar.mtar_t, data: ?*const anyopaque, size: c_uint) callconv(.C) c_int {
//     _ = tar;
//     _ = data;
//     _ = size;
    
//     // Archived buffer
//     var ptr = data orelse @panic("Null buffer");
//     const buffer: *const []u8 = @ptrCast(*const []u8, @alignCast(@alignOf([]const u8), ptr));
//     _ = buffer;
    
//     // Stream buffer
//     var streamPtr = tar.*.stream orelse @panic("Null buffer");
//     var stream: *[]u8 = @ptrCast(*[]u8, @alignCast(@alignOf([]u8), streamPtr));

//     var fbs = std.io.fixedBufferStream(stream.*);
//     var written = fbs.write(buffer.*) catch |e| {
//         std.debug.print("error: {}\n", .{e});
//         @panic("error");
//     };
//     _ = written;
//     std.debug.print("{}\n", .{written});

//     return mtar.MTAR_ESUCCESS;
// }