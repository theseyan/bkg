const std = @import("std");

// Whether debug mode is enabled
pub var debug = false;

// Starting timestamp for measuring app lifetime
pub var startTime: i64 = undefined;

// Allocator
var allocator: std.mem.Allocator = undefined;

// Prints a debug message
pub fn print(comptime msg: []const u8, args: anytype) void {

    std.debug.print("[bkg] " ++ msg ++ "\n", args);

}

// Prints a error message
pub fn err(comptime msg: []const u8, args: anytype) void {
    std.debug.print("❌ " ++ msg ++ "\n", args);
}

// Prints a warning message
pub fn warn(comptime msg: []const u8, args: anytype) void {
    std.debug.print("⚠️ " ++ msg ++ "\n", args);
}

pub fn init(alloc: std.mem.Allocator) void {
    allocator = alloc;
}