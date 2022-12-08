const std = @import("std");
const cli = @import("cli.zig");

// Allocator
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var arena = std.heap.ArenaAllocator.init(gpa.allocator());
var allocator = arena.allocator();

pub fn main() anyerror!void {

    // Free all memory for the program when main exits
    defer arena.deinit();

    // Initialize CLI
    try cli.init(allocator);

}