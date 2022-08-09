const std = @import("std");
const utils = @import("utils.zig");
const lz4 = @import("translated/liblz4.zig");
const mtar = @import("translated/libmicrotar.zig");
const clap = @import("clap");

const debug = std.debug;
const io = std.io;

// Allocator
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

// 66 bytes

pub fn main() anyerror!void {
    const paramsStr = 
        \\-h, --help             Display this help and exit.
        \\-n, --number <usize>   An option parameter, which takes a value.
        \\-s, --string <str>...  An option parameter which can be specified multiple times.
        \\<str>...
        \\
    ;
    const params = comptime clap.parseParamsComptime(paramsStr);
    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
    }) catch |err| {
        diag.report(io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();

    // Parse params
    if (res.args.help)
        debug.print("{s}\n", .{paramsStr});
    if (res.args.number) |n|
        debug.print("--number = {}\n", .{n});
    for (res.args.string) |s|
        debug.print("--string = {s}\n", .{s});
    for (res.positionals) |pos|
        debug.print("{s}\n", .{pos});
}