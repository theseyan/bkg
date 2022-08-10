const std = @import("std");
const compiler = @import("compiler.zig");
const runtime = @import("runtime.zig");

// Allocator
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var arena = std.heap.ArenaAllocator.init(gpa.allocator());
var allocator = arena.allocator();

const example_root = "/home/theseyan/Zig/bkg/example";
const temp_dir = "/home/theseyan/Zig/bkg/tmp";
const bun = "/home/theseyan/.bun/bin/bun";
const target_exe = "/home/theseyan/Zig/bkg/bkg";

pub fn main() anyerror!void {

    // Build archive
    try compiler.buildArchive(allocator, bun, example_root);

    // Compress and package archive into target executable
    try compiler.compressArchive(allocator, target_exe);

    // Extract archive
    try runtime.extractArchive(allocator, target_exe, temp_dir);

    // Launch Bun runtime
    try runtime.execProcess(allocator, temp_dir);

}