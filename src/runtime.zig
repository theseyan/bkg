// Inflates & extracts Bun & source files at runtime
const process = std.process;
const fs = std.fs;
const ChildProcess = std.ChildProcess;
const std = @import("std");
const lz4 = @import("translated/liblz4.zig");
const mtar = @import("translated/libmicrotar.zig");
const Config = @import("config.zig").Config;

const ParseResult = struct {
    compressed: usize,
    hash: []const u8
};

// Parses a bkg binary to get the compressed size header and CRC32 hash
pub fn parseBinary(allocator: std.mem.Allocator, path: []const u8) anyerror!ParseResult {

    var file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    // Seek to 20 bytes before the end
    var stat = try file.stat();
    try file.seekTo(stat.size - 20);
    
    // Read 20 bytes
    const buf: []const u8 = try file.readToEndAlloc(allocator, 1024);
    defer allocator.free(buf);

    var crcBuf = buf[0..10];
    var compSizeBuf = buf[10..20];

    // Parse into usize
    var nullIndex = std.mem.indexOfScalar(u8, compSizeBuf, 0) orelse 10;
    var crcNullIndex = std.mem.indexOfScalar(u8, crcBuf, 0) orelse 10;

    //var crc32 = try allocator.dupe(u8, crcBuf);
    var compSize = std.fmt.parseInt(usize, compSizeBuf[0..nullIndex], 0) catch {
        return error.FailedParseCompressedSize;
    };

    return ParseResult{
        .compressed = compSize,
        .hash = try allocator.dupe(u8, crcBuf[0..crcNullIndex])
    };

}

// Extracts compressed archive from a binary, decompresses it
// and then de-archives it to a temporary location in the filesystem
// We prefer OS temp directory because it's always world writeable.
// However, this may change.
pub fn extractArchive(allocator: std.mem.Allocator, target: []const u8, root: []const u8, parsed: ParseResult) anyerror!void {

    // Open binary
    var file = try std.fs.openFileAbsolute(target, .{});
    defer file.close();

    // Seek to start of compressed archive
    var stat = try file.stat();
    try file.seekTo(stat.size - parsed.compressed - 20); // 20 bytes for header

    // Compressed archive can be upto 256MB
    const buf: []u8 = try file.readToEndAlloc(allocator, 256 * 1024 * 1024);
    defer allocator.free(buf);

    // Decompressed archive can be upto 512MB
    var decompressed: []u8 = try allocator.alloc(u8, 512 * 1024 * 1024);
    
    // Perform LZ4 decompression
    var result = lz4.LZ4_decompress_safe(buf[0..parsed.compressed].ptr, decompressed.ptr, @intCast(c_int, parsed.compressed), 512 * 1024 * 1024);

    // Open decompressed archive
    var tar: mtar.mtar_t = std.mem.zeroes(mtar.mtar_t);
    var header: *mtar.mtar_header_t = try allocator.create(mtar.mtar_header_t);
    _ = root;
    _ = mtar_open_mem(&tar, &decompressed[0..@intCast(usize, result)]);

    // std.debug.print("Reading archive...\n", .{});

    // Iterate through the archive
    while (mtar.mtar_read_header(&tar, header) != mtar.MTAR_ENULLRECORD) {
        var nullIndex = std.mem.indexOfScalar(u8, &header.name, 0) orelse header.name.len;
        var name = header.name[0..nullIndex];

        // Create directory
        if(header.type == mtar.MTAR_TDIR) {
            _ = try std.fs.makeDirAbsolute(try std.mem.concat(allocator, u8, &.{root, "/", name}));
        }
        else if(header.type == mtar.MTAR_TREG) {
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

    // Free decompressed buffer
    allocator.free(decompressed);

}

// Initiates Bun runtime after extraction
pub fn execProcess(allocator: std.mem.Allocator, root: []const u8, config: *Config) anyerror!void {

    // Give executable permissions to bun
    var file: ?std.fs.File = std.fs.openFileAbsolute(try std.mem.concat(allocator, u8, &.{root, "/", "bkg_bun"}), .{}) catch |e| switch(e) {
        error.AccessDenied => null,
        else => return e
    };

    // We get an error.AccessDenied if the file is already executable
    // Only chmod if it isn't executable already
    if(file != null) {
        try file.?.chmod(0o755);
        file.?.close();
    }

    var cmd_args = std.ArrayList([]const u8).init(allocator);
    defer cmd_args.deinit();
    try cmd_args.appendSlice(&[_][]const u8{
        try std.mem.concat(allocator, u8, &.{root, "/", "bkg_bun"}),
        try std.mem.concat(allocator, u8, &.{root, "/", config.entry})
    });

    // Add passed commandline arguments
    var iterator = try std.process.argsWithAllocator(allocator);
    defer iterator.deinit();
    _ = iterator.skip();
    while(iterator.next()) |arg| {
        try cmd_args.appendSlice(&[_][]const u8{arg});
    }

    // Initiate child process
    try exec(allocator, "", cmd_args.items);

}

// Starts Bun as a child process, with the entry script
// stdin, stdout & stderr are piped to parent process
pub fn exec(a: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) !void {
    
    _ = cwd;
    var child_process = ChildProcess.init(argv, a);

    child_process.stdout_behavior = .Inherit;
    child_process.spawn() catch |err| {
        std.debug.print("The following command failed:\n", .{});
        return err;
    };

    const term = try child_process.wait();
    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                std.debug.print("The following command exited with error code {any}:\n", .{code});
                return error.CommandFailed;
            }
        },
        else => {
            std.debug.print("The following command terminated unexpectedly:\n", .{});
            return error.CommandFailed;
        },
    }

}

// Callback functions required by microtar
// Streams decompressed LZ4 buffer directly to mtar in memory

fn mtar_mem_write(tar: [*c]mtar.mtar_t, data: ?*const anyopaque, size: c_uint) callconv(.C) c_int {
    _ = tar;
    _ = data;
    _ = size;
    return mtar.MTAR_EWRITEFAIL;
}

// mem_read should supply data to microtar
fn mtar_mem_read(tar: ?*mtar.mtar_t, data: ?*anyopaque, size: c_uint) callconv(.C) c_int {

    const dataPtr = data orelse @panic("Null pointer passed to mtar mem_read");
    const buffer = @ptrCast([*]u8, dataPtr);

    const streamPtr = tar.?.stream;
    const streamBuffer: *[]u8 = @ptrCast(*[]u8, @alignCast(@alignOf([]u8), streamPtr));

    @memcpy(buffer, streamBuffer.*[tar.?.pos..streamBuffer.len].ptr, size);
    //std.mem.copy(u8, buffer[0..size], streamBuffer.*[tar.?.pos..streamBuffer.len]);

    return mtar.MTAR_ESUCCESS;

}

fn mtar_mem_seek(tar: ?*mtar.mtar_t, offset: c_uint) callconv(.C) c_int {
    _ = tar;
    _ = offset;
    return mtar.MTAR_ESUCCESS;
}

fn mtar_mem_close(tar: ?*mtar.mtar_t) callconv(.C) c_int {
    _ = tar;
    return mtar.MTAR_ESUCCESS;
}

fn mtar_open_mem(tar: *mtar.mtar_t, data: *[]u8) c_int {

    tar.write = mtar_mem_write;
    tar.read = mtar_mem_read;
    tar.seek = mtar_mem_seek;
    tar.close = mtar_mem_close;
    tar.stream = data;

    // Return ok
    return mtar.MTAR_ESUCCESS;

}