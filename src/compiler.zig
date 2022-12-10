// Archives source files into TAR and compresses with LZ4
const std = @import("std");
const lz4 = @import("translated/lz4hc.zig");
const mtar = @import("translated/libmicrotar.zig");
const builtin = @import("builtin");
const defaultConfig = @import("config.zig").defaultConfig;

// Performs the build process for a given Bun binary, target, project path and output path
pub fn build(allocator: std.mem.Allocator, bunPath: []const u8, bkgPath: []const u8, target: []const u8, project: []const u8, out: []const u8, debug: bool) anyerror![]const u8 {

    // Make sure outfile path is not an existing directory
    var isDir = std.fs.openDirAbsolute(out, .{}) catch |e| switch(e) {
        else => null
    };
    if(isDir != null) {
        std.debug.print("Output path `{s}` is an existing directory. Please use a different name for the binary.\n", .{out});
        isDir.?.close();
        return error.PathIsDirectory;
    }

    // Build archive
    try buildArchive(allocator, bunPath, project, debug);

    // Copy bkg runtime to temporary directory
    try std.fs.copyFileAbsolute(bkgPath, "/tmp/__bkg_build_runtime", .{});

    // Apply compression and add to binary
    try compressArchive(allocator, "/tmp/__bkg_build_runtime");

    // Rename executable
    try std.fs.renameAbsolute("/tmp/__bkg_build_runtime", out);

    // Give executable permissions
    var file: ?std.fs.File = std.fs.openFileAbsolute(out, .{}) catch |e| switch(e) {
        else => null
    };
    if(file != null) {
        try file.?.chmod(0o777);
        file.?.close();
    }else {
        std.debug.print("Could not mark binary as executable. Run `chmod +x {s}` to do it manually.\n", .{std.fs.path.basename(out)});
    }

    _ = target;
    return out;

}

// Builds a TAR archive given a root directory
pub fn buildArchive(allocator: std.mem.Allocator, bun_path: []const u8, root: []const u8, debug: bool) anyerror!void {
    
    std.debug.print("Building archive...\n", .{});

    // TAR reference
    var tar: mtar.mtar_t = undefined;

    // Open archive for writing
    _ = mtar.mtar_open(&tar, "/tmp/__bkg_build.tar", "w");
    defer _ = mtar.mtar_close(&tar);

    // Recursively search for files
    var dir = try std.fs.openIterableDirAbsolute(root, .{});
    defer dir.close();
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    // Whether bkg.config.json was found while walking
    var customConfig = false;

    // Add sources to archive
    while (try walker.next()) |entry| {
        // Handle directories
        if(entry.kind == .Directory) {
            std.debug.print("Writing directory {s}\n", .{entry.path});
            _ = mtar.mtar_write_dir_header(&tar, (try allocator.dupe(u8, entry.path)).ptr);
            continue;
        }

        // Check if custom config file is present
        if(std.mem.eql(u8, entry.path, "bkg.config.json")) customConfig = true;

        // Read source into buffer
        var file = std.fs.openFileAbsolute(try std.mem.concat(allocator, u8, &.{root, "/", entry.path}), .{}) catch |e| {
            std.debug.print("Could not open {s}: {any}. Skipping...\n", .{entry.path, e});
            continue;
        };
        const buf: []u8 = try file.readToEndAlloc(allocator, 1024 * 1024 * 1024);

        std.debug.print("Writing file {s} with {} bytes\n", .{entry.path, buf.len});

        // Write buffer to archive
        _ = mtar.mtar_write_file_header(&tar, (try allocator.dupe(u8, entry.path)).ptr, @intCast(c_uint, buf.len));
        _ = mtar.mtar_write_data(&tar, buf.ptr, @intCast(c_uint, buf.len));

        // Close & free memory for this file
        allocator.free(buf);
        file.close();
    }

    // If no custom config is present, add default config to archive
    if(customConfig == false) {
        std.debug.print("Configuration file not found, using default\n", .{});

        var newConfig = defaultConfig;
        if(debug) newConfig.debug = true;

        var configString = try std.json.stringifyAlloc(allocator, newConfig, .{});
        defer allocator.free(configString);

        _ = mtar.mtar_write_file_header(&tar, "bkg.config.json", @intCast(c_uint, configString.len));
        _ = mtar.mtar_write_data(&tar, configString.ptr, @intCast(c_uint, configString.len));
    }
    
    // Add Bun binary to archive
    {
        std.debug.print("Adding Bun binary...\n", .{});
        var bun = try std.fs.openFileAbsolute(bun_path, .{});
        const bunBuf: []u8 = try bun.readToEndAlloc(allocator, 256 * 1024 * 1024);

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
    var archive = try std.fs.openFileAbsolute("/tmp/__bkg_build.tar", .{});
    const buf: []u8 = try archive.readToEndAlloc(allocator, 5 * 1024 * 1024 * 1024); // We assume the archive is <= 5 GiB
    defer allocator.free(buf);

    // Delete temporary archive file
    archive.close();
    try std.fs.deleteFileAbsolute("/tmp/__bkg_build.tar");

    // Allocate 512 MiB buffer for storing compressed archive
    var compressed: []u8 = try allocator.alloc(u8, 512 * 1024 * 1024);
    defer allocator.free(compressed);

    // Perform LZ4 HC compression with compression level 12 (max)
    var compSize = lz4.LZ4_compress_HC(buf.ptr, compressed.ptr, @intCast(c_int, buf.len), 512 * 1024 * 1024, @intCast(c_int, 12));

    std.debug.print("Compressed to {} bytes\n", .{compSize});

    // Calculate CRC32 Hash from the LZ4 compressed buffer
    // This is added to the binary and prevents outdated cached code from
    // stopping an updated executable extracting new code.
    var hashFunc = std.hash.Crc32.init();
    hashFunc.update(compressed[0..@intCast(usize, compSize)]);
    var hash = hashFunc.final();

    std.debug.print("Calculated CRC32 hash: {any}\n", .{hash});

    var file = try std.fs.openFileAbsolute(target, .{.mode = .read_write});
    defer file.close();

    // Seek to end of binary
    var stat = try file.stat();
    try file.seekTo(stat.size);

    std.debug.print("Writing archive to binary...\n", .{});

    // Write compressed archive to binary
    _ = try file.writeAll(compressed[0..@intCast(usize, compSize)]);
    std.debug.print("Written {} bytes to binary\n", .{compSize});

    // Write CRC32 hash + compressed size (10 + 10) bytes at the end
    {
        std.debug.print("Finalizing binary...\n", .{});
        var compSizeBuffer: []u8 = try allocator.alloc(u8, 10);
        var hashBuffer: []u8 = try allocator.alloc(u8, 10);
        defer allocator.free(compSizeBuffer);
        defer allocator.free(hashBuffer);

        var compSizeBufferStream = std.io.fixedBufferStream(compSizeBuffer);
        var hashBufferStream = std.io.fixedBufferStream(hashBuffer);
        try std.fmt.format(compSizeBufferStream.writer(), "{}", .{compSize});
        try std.fmt.format(hashBufferStream.writer(), "{}", .{hash});

        _ = try file.writeAll(hashBuffer);
        _ = try file.writeAll(compSizeBuffer);
    }
    std.debug.print("Done\n", .{});

}

// Creates and returns a standard target string for Host OS
pub fn getHostTargetString(allocator: std.mem.Allocator) ![]const u8 {

    const tag = builtin.target.os.tag;
    const arch = builtin.target.cpu.arch;
    
    var tagStr = switch(tag) {
        .windows => "windows",
        .linux => "linux",
        .macos => "macos",
        else => return error.UnknownOs
    };

    var archStr = switch(arch) {
        .aarch64 => "aarch64",
        .x86_64 => "x86_64",
        else => return error.UnknownCpu
    };

    const target = try std.mem.concat(allocator, u8, &.{archStr, "-", tagStr});
    return target;

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