// Archives source files into TAR and compresses with LZ4
const std = @import("std");
const lz4 = @import("translated/lz4hc.zig");
const mtar = @import("translated/libmicrotar.zig");
const builtin = @import("builtin");
const defaultConfig = @import("config.zig").defaultConfig;
const debug = @import("debug.zig");

// Performs the build process for a given Bun binary, target, project path and output path
pub fn build(allocator: std.mem.Allocator, bunPath: []const u8, bkgPath: []const u8, target: []const u8, project: []const u8, out: []const u8, isDebug: bool) anyerror![]const u8 {

    // Make sure outfile path is not an existing directory
    var isDir = std.fs.openDirAbsolute(out, .{}) catch |e| switch(e) {
        else => null
    };
    if(isDir != null) {
        std.debug.print("Output path `{s}` is an existing directory. Please use a different name for the binary.\n", .{out});
        isDir.?.close();
        return error.PathIsDirectory;
    }
    
    // Copy bkg runtime to temporary directory
    try std.fs.copyFileAbsolute(bkgPath, "/tmp/__bkg_build_runtime", .{});

    // Build archive and apply compression
    try compressArchive(allocator, try buildArchive(allocator, bunPath, project, isDebug), "/tmp/__bkg_build_runtime");

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
pub fn buildArchive(allocator: std.mem.Allocator, bun_path: []const u8, root: []const u8, isDebug: bool) ![]u8 {
    
    std.debug.print("Building archive...\n", .{});

    // Allocate 512 MiB for storing compressed buffer
    var buffer = try allocator.alloc(u8, 512 * 1024 * 1024);

    // TAR archive
    var tar = try allocator.create(mtar.mtar_t);
    var memStream = try allocator.create(mtar.mtar_mem_stream_t);
    defer allocator.destroy(tar);
    defer allocator.destroy(memStream);

    tar.* = std.mem.zeroes(mtar.mtar_t);
    memStream.* = std.mem.zeroes(mtar.mtar_mem_stream_t);
    _ = mtar.mtar_init_mem_stream(memStream, buffer.ptr, buffer.len);
    _ = mtar.mtar_open_mem(tar, memStream);

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
            _ = mtar.mtar_write_dir_header(tar, (try allocator.dupeZ(u8, entry.path)).ptr);
            continue;
        }

        // Check if custom config file is present
        if(std.mem.eql(u8, entry.path, "bkg.config.json")) customConfig = true;

        // Read source into buffer
        var file = std.fs.openFileAbsolute(try std.mem.concat(allocator, u8, &.{root, "/", entry.path}), .{}) catch |e| {
            std.debug.print("Could not open {s}: {any}. Skipping...\n", .{entry.path, e});
            continue;
        };
        const buf: [:0]u8 = try file.readToEndAllocOptions(allocator, 1024 * 1024 * 1024, null, @alignOf(u8), 0);
        const mode = try file.mode();

        if(mode & 0o100 == 0o100) {
            std.debug.print("{s} is executable\n", .{entry.path});
        }

        std.debug.print("Writing file {s} with {any} bytes\n", .{entry.path, @intCast(c_uint, buf.len)});

        // Write buffer to archive
        _ = mtar.mtar_write_file_header(tar, (try allocator.dupeZ(u8, entry.path)).ptr, @intCast(c_uint, buf.len));
        _ = mtar.mtar_write_data(tar, buf.ptr, @intCast(c_uint, buf.len));

        // Close & free memory for this file
        allocator.free(buf);
        file.close();
    }

    // If no custom config is present, add default config to archive
    if(customConfig == false) {
        std.debug.print("Configuration file not found, using default\n", .{});

        var newConfig = defaultConfig;
        if(isDebug) newConfig.debug = true;

        var configString = try std.json.stringifyAlloc(allocator, newConfig, .{});
        defer allocator.free(configString);

        _ = mtar.mtar_write_file_header(tar, "bkg.config.json", @intCast(c_uint, configString.len));
        _ = mtar.mtar_write_data(tar, configString.ptr, @intCast(c_uint, configString.len));
    }
    
    // Add Bun binary to archive
    {
        std.debug.print("Adding Bun binary...\n", .{});
        var bun = try std.fs.openFileAbsolute(bun_path, .{});
        const bunBuf: []u8 = try bun.readToEndAlloc(allocator, 256 * 1024 * 1024);

        _ = mtar.mtar_write_file_header(tar, "bkg_bun", @intCast(c_uint, bunBuf.len));
        _ = mtar.mtar_write_data(tar, bunBuf.ptr, @intCast(c_uint, bunBuf.len));

        allocator.free(bunBuf);
        bun.close();
    }

    // Finalize the archive
    _ = mtar.mtar_finalize(tar);
    _ = mtar.mtar_close(tar);

    std.debug.print("Finalized archive\n", .{});

    return buffer[0..memStream.pos];

}

// Applies LZ4 compression on given TAR archive
pub fn compressArchive(allocator: std.mem.Allocator, buf: []u8, target: []const u8) !void {
    
    std.debug.print("Compressing archive...\n", .{});

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
        var compSizeBuffer: []u8 = try std.fmt.allocPrint(allocator, "{d}", .{compSize});
        var hashBuffer: []u8 = try std.fmt.allocPrint(allocator, "{d}", .{hash});
        var compSizeBuf10 = try allocator.alloc(u8, 10);
        var hashBuf10 = try allocator.alloc(u8, 10);
        defer allocator.free(compSizeBuffer);
        defer allocator.free(hashBuffer);

        // Fill empty bytes with 0s
        for(compSizeBuf10[0..10]) |_, i| {
            if(i >= compSizeBuffer.len) { compSizeBuf10[i] = 0; }
            else { compSizeBuf10[i] = compSizeBuffer[i]; }
        }
        for(hashBuf10[0..10]) |_, i| {
            if(i >= hashBuffer.len) { hashBuf10[i] = 0; }
            else { hashBuf10[i] = hashBuffer[i]; }
        }

        _ = try file.writeAll(hashBuf10);
        _ = try file.writeAll(compSizeBuf10);
    }

    std.debug.print("Done\n", .{});

    // Free compressed buffer
    allocator.free(buf);

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