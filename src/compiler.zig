// Archives source files into TAR and compresses with LZ4
const std = @import("std");
const lz4 = @import("translated/liblz4.zig");
const mtar = @import("translated/libmicrotar.zig");

// Builds a TAR archive given a root directory
pub fn buildArchive(allocator: std.mem.Allocator, root: []const u8) anyerror!void {
    
    // TAR archive
    var tar: mtar.mtar_t = undefined;

    // Open archive for writing
    _ = mtar.mtar_open(&tar, "test.tar", "w");
    defer _ = mtar.mtar_close(&tar);

    // Recursively search for files
    var dir = try std.fs.openDirAbsolute(root, .{ .iterate = true });
    defer dir.close();
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        // Skip directories
        if(entry.kind == .Directory) continue;

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

    // Finalize the archive
    _ = mtar.mtar_finalize(&tar);

}

// Applies LZ4 compression on given TAR archive
pub fn compressArchive(allocator: std.mem.Allocator) anyerror!void {

}

pub fn saveCompressed(allocator: std.mem.Allocator) anyerror!void {

    var bun = try std.fs.cwd().openFile("lmao.txt", .{});
    defer bun.close();
    const buf: []u8 = try bun.readToEndAlloc(allocator, 1024 * 1024 * 1024);

    //const str = "lmao im seyan yea boi im seyan idk whats wrong with me lmao lmao im seyan yea boi im seyan idk whats wrong with me lmao lmao im seyan yea boi im seyan idk whats wrong with me lmao lmao im seyan yea boi im seyan idk whats wrong with me lmao lmao im seyan yea boi im seyan idk whats wrong with me lmao";
    var compressed: []u8 = try allocator.alloc(u8, 1024 * 1024 * 128);
    defer allocator.free(compressed);
    var compSize = lz4.LZ4_compress_default(buf.ptr, compressed.ptr, @intCast(c_int, buf.len), 1024 * 1024 * 128);

    var file = try std.fs.cwd().openFile("bun", .{.mode = .read_write});
    defer file.close();

    // Seek to end of binary
    var stat = try file.stat();
    try file.seekTo(stat.size);

    std.debug.print("Seeked to {} bytes\n", .{stat.size});

    var written = try file.write(compressed[0..@intCast(usize, compSize)]);
    std.debug.print("Compressed: {} bytes\nWritten: {} bytes\n", .{compSize, written});

}

pub fn writeArchive() anyerror!void {
    var tar: mtar.mtar_t = undefined;
    const str1 = "Hello world";
    const str2 = "Goodbye world";

    // Open archive for writing
    _ = mtar.mtar_open(&tar, "test.tar", "w");

    // Write strings to files `test1.txt` and `test2.txt`
    _ = mtar.mtar_write_file_header(&tar, "idk/man/test1.txt", str1.len);
    _ = mtar.mtar_write_data(&tar, str1, str1.len);
    _ = mtar.mtar_write_file_header(&tar, "test2.txt", str2.len);
    _ = mtar.mtar_write_data(&tar, str2, str2.len);

    // Finalize -- this needs to be the last thing done before closing
    _ = mtar.mtar_finalize(&tar);

    // Close archive
    _ = mtar.mtar_close(&tar);
}