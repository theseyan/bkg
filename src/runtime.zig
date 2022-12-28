// Inflates & extracts Bun & source files at runtime
const process = std.process;
const fs = std.fs;
const ChildProcess = std.ChildProcess;
const std = @import("std");
const lz4 = @import("translated/liblz4.zig");
const mtar = @import("translated/libmicrotar.zig");
const config = @import("config.zig");
const threadpool = @import("thread_pool.zig");
const debug = @import("debug.zig");

const ParseResult = struct {
    compressed: usize,
    hash: []const u8
};

// Used during multithreaded extraction
var pool: threadpool = undefined;
var alloc: std.mem.Allocator = undefined;
var extractRoot: []const u8 = undefined;
var m1 = std.Thread.Mutex{};
var m2 = std.Thread.Mutex{};
var numTasks: usize = undefined;

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

    var crcBuf: []const u8 = buf[0..10];
    var compSizeBuf: []const u8 = buf[10..20];

    // Parse into usize
    var nullIndex = std.mem.indexOfScalar(u8, compSizeBuf, 0) orelse 10;

    //var crc32 = try allocator.dupe(u8, crcBuf);
    var compSize = std.fmt.parseInt(usize, compSizeBuf[0..nullIndex], 0) catch {
        return error.FailedParseCompressedSize;
    };

    return ParseResult{
        .compressed = compSize,
        .hash = try allocator.dupe(u8, crcBuf[0..10])
    };

}

// Worker function that extracts a single file and writes it to disk
// This function may be called from multiple threads, simultaneously
fn extractCallback(op: *threadpool.Task) void {
    
    var name = op.data.name orelse return;

    var header = op.data.header;
    var tar = op.data.tar;    

    // Allocate memory for this file
    var fileBuf: []u8 = alloc.alloc(u8, header.size) catch @panic("Failed to allocate memory for extracted file!");

    m1.lock();
    {
        // Read contents of the file
        _ = mtar.mtar_read_data(tar, fileBuf.ptr, header.size);

        // Write file to disk
        var exfile = std.fs.createFileAbsolute(std.mem.concat(alloc, u8, &.{extractRoot, "/", name}) catch @panic("Failed to concat during extraction!"), .{.read = false}) catch |e| {
            std.debug.print("Failed to create {s} during extraction: {s}\n", .{name, @errorName(e)});
            @panic("exiting due to FS error");
        };
        _ = exfile.writeAll(fileBuf) catch @panic("Failed to write file contents");

        // Close and free resources
        exfile.close();
        alloc.free(fileBuf);
        _ = mtar.mtar_close(tar);
        alloc.destroy(op.data.tar);
        alloc.destroy(op.data.header);
        alloc.destroy(op.data);
    }
    m1.unlock();

    // We must lock to prevent race conditions and other weird errors
    // due to massive concurrency
    {
        m2.lock();
        op.data.index.* += 1;
        if(op.data.index.* == numTasks) pool.shutdown();
        m2.unlock();
    }

}

// Extracts compressed archive from a binary, decompresses it
// and then de-archives it to a temporary location in the filesystem
// We prefer OS temp directory because it's always world writeable.
// However, this may change.
pub fn extractArchive(allocator: std.mem.Allocator, target: []const u8, root: []const u8, parsed: ParseResult) !void {

    alloc = allocator;
    extractRoot = root;

    // Open binary
    var file = try std.fs.openFileAbsolute(target, .{});
    defer file.close();

    // Seek to start of compressed archive
    var stat = try file.stat();
    try file.seekTo(stat.size - parsed.compressed - 20); // 20 bytes for header

    // Compressed archive can be upto 512MB
    const buf: []u8 = try file.readToEndAlloc(allocator, 512 * 1024 * 1024);
    defer allocator.free(buf);

    // Decompressed archive can be upto 1024MB
    var decompressed: []u8 = try allocator.alloc(u8, 1024 * 1024 * 1024);
    
    // Store timestamp used for profiling
    debug.startTime = std.time.milliTimestamp();

    // Perform LZ4 decompression
    var result = lz4.LZ4_decompress_safe(buf[0..parsed.compressed].ptr, decompressed.ptr, @intCast(c_int, parsed.compressed), 1024 * 1024 * 1024);

    //std.debug.print("[{any}] Decompressed {any} bytes to memory\n", .{std.time.milliTimestamp() - debug.startTime, result});

    // Open decompressed archive
    var tar: mtar.mtar_t = std.mem.zeroes(mtar.mtar_t);
    var header: *mtar.mtar_header_t = try allocator.create(mtar.mtar_header_t);
    _ = mtar_open_mem(&tar, decompressed[0..@intCast(usize, result)].ptr);

    // Load configuration file before everything else
    _ = mtar.mtar_find(&tar, "bkg.config.json", header);
    var configBuf: []u8 = alloc.alloc(u8, header.size) catch @panic("Failed to allocate memory for configuration file!");
    _ = mtar.mtar_read_data(&tar, configBuf.ptr, header.size);
    _ = mtar.mtar_rewind(&tar);
    config.load(allocator, null, configBuf) catch @panic("Failed to parse configuration file!");
    debug.debug = config.get().debug;

    if(debug.debug) {
        debug.init(allocator);
        debug.print("Debug logs are enabled", .{});
        debug.print("Configuration file loaded from archive!", .{});
    }

    // Initialize threadpool with number of threads available in OS
    const threads = try std.Thread.getCpuCount();
    pool = threadpool.init(.{
        .max_threads = @intCast(u32, threads)
    });

    if(debug.debug) debug.print("Initialized thread pool using {any} threads", .{threads});

    // Initial no-op task
    var initData = threadpool.ExtractData{
        .name = null,
        .buffer = undefined,
        .bufSize = undefined,
        .index = undefined,
        .header = undefined,
        .tar = undefined
    };
    var initTaskStruct = threadpool.Task{
        .callback = extractCallback,
        .data = &initData
    };
    var initTask = &initTaskStruct;

    //var batch = try allocator.create(threadpool.Batch);
    var batch = threadpool.Batch.from(initTask);

    // Used to track progress across tasks
    var index = try allocator.create(usize);
    index.* = 0;

    // Iterate through the archive
    while (mtar.mtar_read_header(&tar, header) != mtar.MTAR_ENULLRECORD) {
        var nullIndex = std.mem.indexOfScalar(u8, &header.name, 0) orelse header.name.len;
        var name = header.name[0..nullIndex];

        // Create directory
        if(header.type == mtar.MTAR_TDIR) {
            _ = try std.fs.makeDirAbsolute(try std.mem.concat(allocator, u8, &.{root, "/", name}));
        }
        else if(header.type == mtar.MTAR_TREG) {
            var task = try allocator.create(threadpool.Task);
            var data = try allocator.create(threadpool.ExtractData);

            // Allocate TAR and header objects for this task
            var dupeTar: *mtar.mtar_t = alloc.create(mtar.mtar_t) catch @panic("Failed to allocate TAR struct");

            dupeTar.* = tar;
            var dupeHeader = try allocator.create(mtar.mtar_header_t);
            dupeHeader.* = header.*;

            data.* = .{
                .name = dupeHeader.name[0..(std.mem.indexOfScalar(u8, &dupeHeader.name, 0) orelse dupeHeader.name.len)],
                .header = dupeHeader,
                .buffer = &decompressed,
                .bufSize = &result,
                .index = index,
                .tar = dupeTar
            };

            task.* = threadpool.Task{
                .callback = extractCallback,
                .data = data
            };

            // Push task to batch
            var newbatch = threadpool.Batch.from(task);
            batch.push(newbatch);
        }

        _ = mtar.mtar_next(&tar);
    }
    
    numTasks = batch.len - 1;
    if(debug.debug) debug.print("Scheduling write batch with {any} tasks ({any}ms)", .{numTasks, std.time.milliTimestamp() - debug.startTime});

    // Schedule tasks to thread pool
    pool.schedule(batch);

    // Wait for completion
    pool.deinit();

    if(debug.debug) debug.print("Extracted to disk! ({any}ms)", .{std.time.milliTimestamp() - debug.startTime});

    // Close the archive
    _ = mtar.mtar_close(&tar);

    // Free decompressed buffer
    allocator.free(decompressed);

}

// (Old) Single threaded implementation of the extractor
// This is ~30x slower than the newer multithreaded implementation on a 12-threads CPU
pub fn extractArchiveSingleThreaded(allocator: std.mem.Allocator, target: []const u8, root: []const u8, parsed: ParseResult) anyerror!void {

    // Open binary
    var file = try std.fs.openFileAbsolute(target, .{});
    defer file.close();

    // Seek to start of compressed archive
    var stat = try file.stat();
    try file.seekTo(stat.size - parsed.compressed - 20); // 20 bytes for header

    // Compressed archive can be upto 512MB
    const buf: []u8 = try file.readToEndAlloc(allocator, 512 * 1024 * 1024);
    defer allocator.free(buf);

    // Decompressed archive can be upto 1024MB
    var decompressed: []u8 = try allocator.alloc(u8, 1024 * 1024 * 1024);
    
    debug.startTime = std.time.milliTimestamp();

    // Perform LZ4 decompression
    var result = lz4.LZ4_decompress_safe(buf[0..parsed.compressed].ptr, decompressed.ptr, @intCast(c_int, parsed.compressed), 1024 * 1024 * 1024);

    //std.debug.print("[{any}] Decompressed to memory\n", .{std.time.milliTimestamp() - startTime});

    // Open decompressed archive
    var tar: mtar.mtar_t = std.mem.zeroes(mtar.mtar_t);
    var memStream: mtar.mtar_mem_stream_t = std.mem.zeroes(mtar.mtar_mem_stream_t);
    var header: *mtar.mtar_header_t = try allocator.create(mtar.mtar_header_t);

    _ = mtar.mtar_init_mem_stream(&memStream, decompressed[0..@intCast(usize, result)].ptr, @intCast(usize, result));
    _ = mtar.mtar_open_mem(&tar, &memStream);
    
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

    //std.debug.print("[{any} ms] Extracted everything\n", .{std.time.milliTimestamp() - startTime});

    // Close the archive
    _ = mtar.mtar_close(&tar);

    // Free decompressed buffer
    allocator.free(decompressed);

}

// Initiates Bun runtime after extraction
pub fn execProcess(allocator: std.mem.Allocator, root: []const u8, configuration: *config.Config) anyerror!void {

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
        try std.mem.concat(allocator, u8, &.{root, "/", configuration.entry})
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
    
    // TODO: Return error on null pointer?
    const dataPtr = data orelse return mtar.MTAR_ENULLRECORD;
    const thisTar = tar orelse return mtar.MTAR_EFAILURE;

    const buffer = @ptrCast([*]u8, @alignCast(@alignOf(u8), dataPtr));
    const streamPtr = thisTar.stream orelse return mtar.MTAR_ENULLRECORD;
    const streamBuffer: [*]u8 = @ptrCast([*]u8, @alignCast(@alignOf([*]u8), streamPtr));

    //const end = if (streamBuffer.*.len < (thisTar.pos + size)) streamBuffer.*.len else (thisTar.pos + size);
    for (streamBuffer[thisTar.pos..(thisTar.pos + size)]) |b, i| buffer[i] = b;
    
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

fn mtar_open_mem(tar: *mtar.mtar_t, data: [*]u8) c_int {

    tar.write = mtar_mem_write;
    tar.read = mtar_mem_read;
    tar.seek = mtar_mem_seek;
    tar.close = mtar_mem_close;
    tar.stream = data;

    // Return ok
    return mtar.MTAR_ESUCCESS;

}