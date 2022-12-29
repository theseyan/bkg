// Combines the analyzer and optimizer to perform Link Time Optimizations (LTO)

const std = @import("std");
const optimizer = @import("optimizer.zig");
const analyzer = @import("analyzer.zig");
const debug = @import("debug.zig");

var allocator: std.mem.Allocator = undefined;
var root: []const u8 = undefined;
var tempDir: []const u8 = undefined;
var includes: [][]const u8 = &.{};

// Modules marked as external
// They will not be optimized
var externals: std.ArrayList([]const u8) = undefined;

// External modules with all pure dependencies
// They can be optimized in place
var leafModules: std.ArrayList([]const u8) = undefined;

// Some modules, although being dynamic, can mostly function even when bundled
// This is an inexhaustible list of such exceptions
pub const AllowedDynamicModules = [_][]const u8{"express"};

// Force modules to be marked external, even if they are pure
pub const ForcedExternalModules = [_][]const u8{};

pub fn init(alloc: std.mem.Allocator, rootDir: []const u8, includesArray: [][]const u8) !void {
    try analyzer.init(alloc);
    allocator = alloc;
    root = rootDir;
    includes = includesArray;

    // Create temporary build directory
    tempDir = try createTempBuildDir();
}

// Performs LTO on an entrypoint
pub fn LTO(entry: []const u8, format: []const u8) ![]const u8 {

    // Mark externals and leaf modules
    try markExternals(entry, format);

    // Optimize every leaf module in-place
    for(leafModules.items[0..leafModules.items.len]) |leaf| {
        std.debug.print("Optimizing leaf `{s}` in-place...\n", .{leaf});
        const entrypoint = try analyzer.getModulePtr(leaf);
        try optimizer.optimizePureModuleToDisk(allocator, leaf, try std.mem.concat(allocator, u8, &.{root, "/node_modules/", leaf, "/", entrypoint.main}), tempDir);
    }

    // Copy every external module 
    for(externals.items[0..externals.items.len]) |external| {
        std.debug.print("Copying external `{s}`...\n", .{external});
        try optimizer.copyModuleToDisk(allocator, root, external, tempDir);
    }

    // Copy included assets
    std.debug.print("Copying assets...\n", .{});
    var dir = try std.fs.openIterableDirAbsolute(root, .{});
    defer dir.close();
    var walker = try dir.walk(allocator);

    while (try walker.next()) |file| {
        if(file.kind == .Directory) continue;
        for(includes[0..includes.len]) |glob| {
            if(analyzer.globMatch(glob, file.path)) {
                const basename = std.fs.path.basename(file.path);

                // Make sure directory exists
                try std.fs.cwd().makePath(try std.mem.concat(allocator, u8, &.{tempDir, "/", file.path[0..(file.path.len - basename.len - 1)]}));

                std.debug.print("Copying `{s}`...\n", .{file.path});

                // Copy the file
                try std.fs.copyFileAbsolute(try std.mem.concat(allocator, u8, &.{root, "/", file.path}), try std.mem.concat(allocator, u8, &.{tempDir, "/", file.path}), .{});
            }
        }
    }

    // Optimize application entrypoint
    std.debug.print("Optimizing entrypoint...\n", .{});
    const externalsString = try std.mem.concat(allocator, u8, &.{try std.mem.join(allocator, ",", externals.items), ","});
    var result = try optimizer.optimize(allocator, try std.mem.concat(allocator, u8, &.{root, "/", entry}), try std.mem.concat(allocator, u8, &.{tempDir, "/index.js"}), format, externalsString);

    if(result.status == .Failure) {
        return error.LTOFailedOptimizeEntrypoint;
    }else if(result.status == .Warning) {
        for(result.warnings[0..result.warnings.len]) |warning| {
            debug.warn("Warning: `{?s}` [{?s}:{?d}:{?d}]", .{warning.Location.?.LineText, warning.Location.?.File, warning.Location.?.Line, warning.Location.?.Column});
            debug.print("{s}", .{warning.Text});
        }
    }
    
    std.debug.print("⚡ Bundled and optimized application code ({any} KiB)!\n", .{@divTrunc(result.meta.bundleSize, 1024)});
    return tempDir;

}

// Cleans up build artifacts generated during LTO
pub fn cleanup() !void {
    try std.fs.cwd().deleteTree(tempDir);
}

// Creates a temporary directory for storing build assets
// Should be deleted after compilation
fn createTempBuildDir() ![]const u8 {
    var timeBuffer: []u8 = try allocator.alloc(u8, 13);
    var timeBufferStream = std.io.fixedBufferStream(timeBuffer);
    defer allocator.free(timeBuffer);

    try std.fmt.format(timeBufferStream.writer(), "{}", .{std.time.milliTimestamp()});
    var path = try std.mem.concat(allocator, u8, &.{"/tmp/.__bkg-build-", timeBuffer});
    try std.fs.makeDirAbsolute(path);

    return path;
}

// Statically analyzes node_modules to find native modules
// Gets dynamic modules and marks external modules
pub fn markExternals(entry: []const u8, format: []const u8) !void {

    const nodeModules = try std.mem.concat(allocator, u8, &.{root, "/node_modules"});
    const entryAbsolute = try std.mem.concat(allocator, u8, &.{root, "/", entry});

    // Run static analyzer
    var modules = try analyzer.analyze(allocator, nodeModules);

    // Mark all dynamic and native modules as external
    externals = std.ArrayList([]const u8).init(allocator);
    leafModules = std.ArrayList([]const u8).init(allocator);

    // Mark forced external modules
    for(ForcedExternalModules[0..ForcedExternalModules.len]) |module| {
        recursiveMark(module);
    }

    // Mark native modules
    for(modules.items[0..modules.items.len]) |module| {
        if(std.mem.eql(u8, module.type, "native")) {
            recursiveMark(module.name);
        }
    }

    // Mark dynamic modules
    var dynamicModules = getDynamicModules(entryAbsolute, format) catch |e| switch(e) {
        error.SourceIsDynamic => {
            debug.err("Error: Dynamic require/import found in source code! bkg is unable optimize this with LTO, please rewrite it to a static import or disable LTO with `--nolto` flag.", .{});
            return e;
        },
        else => return e
    };

    for(dynamicModules[0..dynamicModules.len]) |module| {
        recursiveMark(module);
    }
}

// Marks given module and it's native/dynamic dependencies recursively as external
pub fn recursiveMark(module: []const u8) void {

    // Make sure this module isn't already marked
    for(externals.items[0..externals.items.len]) |item| if(std.mem.eql(u8, item, module)) return;
    for(leafModules.items[0..leafModules.items.len]) |item| if(std.mem.eql(u8, item, module)) return;

    // Get dynamic dependencies of this module
    var modulePtr = analyzer.getModulePtr(module) catch |e| @panic(@errorName(e));
    var dynamicModules = getDynamicModules(std.mem.concatWithSentinel(allocator, u8, &.{root, "/node_modules/", modulePtr.path, "/", modulePtr.main}, 0) catch |e| @panic(@errorName(e)), "cjs") catch |e| @panic(@errorName(e));

    std.debug.print("`{s}` is external module with {any} impure dependencies\n", .{module, dynamicModules.len});
    
    // This module is external, but it has dynamic dependencies which must also be marked
    externals.append(module) catch |e| @panic(@errorName(e));

    // Any pure dependencies are leaf modules
    leafLoop: for(modulePtr.deps[0..modulePtr.deps.len]) |leaf| {
        for(dynamicModules[0..dynamicModules.len]) |mod| { if(std.mem.eql(u8, leaf.path, mod)) continue :leafLoop; }

        leafModules.append(leaf.name) catch |e| @panic(@errorName(e));
        std.debug.print("Marked `{s}` as external leaf module\n", .{leaf.name});
    }

    // Mark dynamic dependencies
    for(dynamicModules[0..dynamicModules.len]) |mod| {
        return recursiveMark(mod);
    }

}

// Checks if given module is in allowed list of exceptions
pub fn checkAllowedDynamicModule(module: []const u8) bool {
    for(AllowedDynamicModules[0..AllowedDynamicModules.len]) |mod| {
        if(std.mem.eql(u8, mod, module)) return true;
    }
    return false;
}

// Runs an optimizer pass to find modules with dynamic imports/requires
pub fn getDynamicModules(entry: []const u8, format: []const u8) ![][]const u8 {
    var tempFile = try std.mem.concat(allocator, u8, &.{tempDir, "/tempOptimizerPass.js"});
    var result = try optimizer.optimize(allocator, entry, tempFile, format, "");
    const nodeModules = try std.mem.concat(allocator, u8, &.{root, "/node_modules"});

    // Delete temp bundled file
    if(result.status != .Failure) { try std.fs.deleteFileAbsolute(tempFile); }
    else {
        for(result.errors[0..result.errors.len]) |err| {
            std.debug.print("LTO Error: {s}\n", .{err.Text});
            std.debug.print("at `{s}` [{s}:{any}:{any}]\n", .{err.Location.?.LineText, err.Location.?.File, err.Location.?.Line, err.Location.?.Column});
        }
        std.debug.print("To build without LTO, you can run with `--nolto`.\n", .{});

        return error.OptimizeFailed;
    }

    var modules = std.ArrayList([]const u8).init(allocator);

    // If there are warnings, there might be dynamic modules
    if(result.status != .Success) {
        for(result.warnings[0..result.warnings.len]) |message| {
            if(std.mem.eql(u8, message.ID.?, "unsupported-require-call") or std.mem.eql(u8, message.ID.?, "unsupported-dynamic-import")) {
                const absPath = try std.fs.cwd().realpathAlloc(allocator, message.Location.?.File);

                // Make sure this is in node_modules
                if(std.mem.startsWith(u8, absPath, nodeModules)) {

                    var iterator = std.mem.split(u8, try std.mem.replaceOwned(u8, allocator, absPath, nodeModules, ""), "/");
                    _ = iterator.next(); // Skip leading slash
                    var currentSearchPath: []u8 = "";

                    // From the file path, get the path/name of module
                    while(iterator.next()) |dir| {
                        currentSearchPath = try std.mem.concat(allocator, u8, &.{currentSearchPath, "/", dir});
                        const fullPath = try std.mem.concat(allocator, u8, &.{nodeModules, currentSearchPath});
                        defer allocator.free(fullPath);

                        if((try analyzer.isModule(allocator, fullPath)) and checkAllowedDynamicModule(currentSearchPath[1..currentSearchPath.len]) == false) {
                            try modules.append(currentSearchPath[1..currentSearchPath.len]);
                        }
                    }

                }else {
                    // We don't support sources that use dynamic imports / requires
                    return error.SourceIsDynamic;
                }
            }
        }
    }

    // Free JSON resources
    defer std.json.parseFree(optimizer.BuildResult, result.buildResult, .{.allocator = allocator, .ignore_unknown_fields = true});
    defer allocator.destroy(result);

    return modules.toOwnedSlice();
}