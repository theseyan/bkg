// Inflates & extracts Bun & source files into /tmp
const std = @import("std");
const lz4 = @import("translated/liblz4.zig");
const mtar = @import("translated/libmicrotar.zig");

pub fn extractFiles(allocator: std.mem.Allocator) anyerror!void {
    var file = try std.fs.cwd().openFile("bun", .{});
    defer file.close();

    var stat = try file.stat();
    _ = stat;
    try file.seekTo(stat.size - 66);

    const buf: []u8 = try file.readToEndAlloc(allocator, 1024 * 1024 * 1024);
    var decompressed: []u8 = try allocator.alloc(u8, 1024);
    
    var result = lz4.LZ4_decompress_safe(buf.ptr, decompressed.ptr, @intCast(c_int, buf.len), 1024);
    std.debug.print("decompressed with result {}: {s}\n", .{result, decompressed});
}