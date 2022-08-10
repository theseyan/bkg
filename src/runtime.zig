// Inflates & extracts Bun & source files at runtime
const std = @import("std");
const lz4 = @import("translated/liblz4.zig");
const mtar = @import("translated/libmicrotar.zig");

// Parses a bkg binary to get the compressed size header
pub fn getCompressedSize(allocator: std.mem.Allocator, path: []const u8) anyerror!usize {
    var file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    // Seek to 10 bytes before the end
    var stat = try file.stat();
    try file.seekTo(stat.size - 10);

    // Read 10 bytes
    const buf: []u8 = try file.readToEndAlloc(allocator, 1024);
    defer allocator.free(buf);

    // Parse into usize
    var nullIndex = std.mem.indexOfScalar(u8, buf, 0) orelse 10;   
    var compSize = try std.fmt.parseInt(usize, buf[0..nullIndex], 0);

    return compSize;
}

// Extracts compressed archive from a binary, decompresses it
// and then de-archives it to a temporary location in the filesystem
// We prefer OS temp directory because it's always world writeable.
// However, this may change.
pub fn extractArchive(allocator: std.mem.Allocator, root: []const u8) anyerror!void {

    // Get number of compressed bytes
    var compSize = try getCompressedSize(allocator, "/home/theseyan/Zig/bkg/bkg");

    // Open binary
    var file = try std.fs.openFileAbsolute("/home/theseyan/Zig/bkg/bkg", .{});
    defer file.close();

    // Seek to start of compressed archive
    var stat = try file.stat();
    try file.seekTo(stat.size - compSize - 10); // 10 bytes for header

    // Compressed archive can be upto 256MB
    const buf: []u8 = try file.readToEndAlloc(allocator, 256 * 1024 * 1024);
    defer allocator.free(buf);

    // Decompressed archive can be upto 512MB
    var decompressed: []u8 = try allocator.alloc(u8, 512 * 1024 * 1024);
    
    // Perform LZ4 decompression
    var result = lz4.LZ4_decompress_safe(buf[0..compSize].ptr, decompressed.ptr, @intCast(c_int, compSize), 512 * 1024 * 1024);
    _ = allocator.resize(decompressed, @intCast(usize, result)); // Resize to decompressed size

    // Write buffer to disk
    const bkg_extracted = "bkg_extracted";
    var decompFile = try std.fs.cwd().createFile(bkg_extracted, .{});
    var decompBytes = try decompFile.write(decompressed);

    std.debug.print("Wrote {} bytes to disk\n", .{decompBytes});

    // Free decompressed buffer
    allocator.free(decompressed);

    // Open decompressed archive
    var tar: mtar.mtar_t = undefined;
    var header: *mtar.mtar_header_t = try allocator.create(mtar.mtar_header_t);
    _ = mtar.mtar_open(&tar, bkg_extracted, "r");

    std.debug.print("Reading archive...\n", .{});
    
    // Iterate through the archive
    while (mtar.mtar_read_header(&tar, header) != mtar.MTAR_ENULLRECORD) {
        var nullIndex = std.mem.indexOfScalar(u8, &header.name, 0) orelse header.name.len;
        var name = header.name[0..nullIndex];

        // Create directory
        if(header.type == mtar.MTAR_TDIR) {
            std.debug.print("Creating directory: {s}\n", .{name});
            _ = try std.fs.makeDirAbsolute(try std.mem.concat(allocator, u8, &.{root, "/", name}));
        }
        else if(header.type == mtar.MTAR_TREG) {
            std.debug.print("Writing file: {s}\n", .{name});

            _ = mtar.mtar_find(&tar, name.ptr, header);
            var fileBuf: []u8 = try allocator.alloc(u8, @intCast(usize, header.size));
            _ = mtar.mtar_read_data(&tar, fileBuf.ptr, header.size);

            var exfile = try std.fs.createFileAbsolute(try std.mem.concat(allocator, u8, &.{root, "/", name}), .{});
            _ = try exfile.write(fileBuf);
            
            exfile.close();
            allocator.free(fileBuf);
        }

        _ = mtar.mtar_next(&tar);
    }

    // Close the archive
    _ = mtar.mtar_close(&tar);

    // Delete temporary archive
    try std.fs.cwd().deleteFile(bkg_extracted);

}

// TODO: Stream LZ4 decompressed buffer directly to mtar in memory
// This will improve startup time by a lot

// Called by microtar
// tar.* = mtar.mtar_t{
//         .stream = &decompressed,
//         .read = extractReadCallback,
//         .seek = extractSeekCallback,
//         .close = extractCloseCallback,
//         .pos = 0,
//         .last_header = 0,
//         .remaining_data = 0,
//         .write = null
//     };
// pub fn extractReadCallback(tar: ?*mtar.mtar_t, data: ?*anyopaque, size: c_uint) callconv(.C) c_int {
//     _ = tar;
//     _ = data;
//     _ = size;

//     var dataPtr = data orelse @panic("Null pointer passed to read callback");
//     var buffer: *[]u8 = @ptrCast(*[]u8, @alignCast(@alignOf([]u8), dataPtr));

//     var tarPtr = tar orelse @panic("Null pointer passed to read callback");
//     var streamPtr = tarPtr.*.stream orelse @panic("Null pointer");
//     var streamBuffer: *[]u8 = @ptrCast(*[]u8, @alignCast(@alignOf([]u8), streamPtr));

//     var reader = std.io.fixedBufferStream(streamBuffer.*);
//     var read = try reader.read(buffer.*);

//     std.debug.print("buf size: {}, size: {}, pos: {}, read {} bytes\n", .{buffer.len, size, tarPtr.*.pos, read});

//     return mtar.MTAR_ESUCCESS;
// }

// pub fn extractSeekCallback(tar: ?*mtar.mtar_t, pos: c_uint) callconv(.C) c_int {
//     _ = tar;
//     _ = pos;

//     std.debug.print("seek called {}\n", .{pos});

//     return mtar.MTAR_ESUCCESS;
// }

// pub fn extractCloseCallback(tar: ?*mtar.mtar_t) callconv(.C) c_int {
//     _ = tar;

//     std.debug.print("close called\n", .{});

//     return mtar.MTAR_ESUCCESS;
// }