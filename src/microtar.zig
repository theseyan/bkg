// TAR Memory archiving/extraction implementation
const std = @import("std");
const mtar = @import("translated/libmicrotar.zig");

// mem_write should write to buffer with data from microtar
pub fn mtar_mem_write(tar: ?*mtar.mtar_t, data: ?*anyopaque, size: c_uint) callconv(.C) c_int {
    //_ = size;
    std.debug.print("im here\n", .{});

    // Buffer to write to stream
    const thisTar = tar orelse return mtar.MTAR_EFAILURE;
    var ptr = data orelse @panic("Null buffer");
    
    std.debug.print("before align buffer\n", .{});
    const buffer: *[]u8 = @ptrCast(*[]u8, @alignCast(@alignOf(*[]u8), ptr));
    //const nullPos = std.mem.indexOfSentinel(u8, 0, buffer.*);

    std.debug.print("before align stream\n", .{});
    // Stream buffer
    var streamPtr = thisTar.*.stream orelse @panic("Null buffer");
    var stream: [*]u8 = @ptrCast([*]u8, @alignCast(@alignOf([*]u8), streamPtr));

    _ = stream;
    _ = size;
    std.debug.print("in mtar: {any} {s}\n", .{thisTar.pos, buffer.*[0..]});

    return mtar.MTAR_ESUCCESS;
}

// mem_read should supply data to microtar
pub fn mtar_mem_read(tar: ?*mtar.mtar_t, data: ?*anyopaque, size: c_uint) callconv(.C) c_int {
    
    // TODO: Return error on null pointer?
    const dataPtr = data orelse return mtar.MTAR_ENULLRECORD;
    const thisTar = tar orelse return mtar.MTAR_EFAILURE;

    const buffer = @ptrCast([*]u8, @alignCast(@alignOf(u8), dataPtr));
    const streamPtr = thisTar.stream orelse return mtar.MTAR_ENULLRECORD;
    const streamBuffer: *[]u8 = @ptrCast(*[]u8, @alignCast(@alignOf(*[]u8), streamPtr));

    const end = if (streamBuffer.*.len < (thisTar.pos + size)) streamBuffer.*.len else (thisTar.pos + size);
    for (streamBuffer.*[thisTar.pos..end]) |b, i| buffer[i] = b;
    //@memcpy(buffer, streamBuffer.*[thisTar.pos..streamBuffer.*.len].ptr, size);
    //std.mem.copy(u8, buffer.*, streamBuffer.*[tar.?.pos..streamBuffer.len]);
    
    return mtar.MTAR_ESUCCESS;

}

pub fn mtar_mem_seek(tar: ?*mtar.mtar_t, offset: c_uint) callconv(.C) c_int {
    _ = tar;
    _ = offset;
    return mtar.MTAR_ESUCCESS;
}

pub fn mtar_mem_close(tar: ?*mtar.mtar_t) callconv(.C) c_int {
    _ = tar;
    return mtar.MTAR_ESUCCESS;
}

pub fn mtar_open_mem(tar: *mtar.mtar_t, data: ?*anyopaque) c_int {

    tar.write = mtar_mem_write;
    tar.read = mtar_mem_read;
    tar.seek = mtar_mem_seek;
    tar.close = mtar_mem_close;
    tar.stream = data;

    // Return ok
    return mtar.MTAR_ESUCCESS;

}