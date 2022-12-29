// Performs bundling, minification and optimization on Javascript sources

const std = @import("std");
const boptimizer = @import("translated/boptimizer.zig");
const json = std.json;
const lto = @import("lto.zig");
const analyzer = @import("analyzer.zig");
const debug = @import("debug.zig");

// Glob patterns to exclude when copying a module
pub const ModuleCopyExcludes = [_][]const u8{
    ".gitignore", ".git", "*.md", ".prettierrc", "tsconfig.base.json", ".github", "LICENSE"
};

pub const BuildResultFileLocation = struct {
    File: []const u8,
    Namespace: []const u8,
    Line: u16,
    Column: u16,
    Length: u16,
    LineText: []const u8,
    Suggestion: []const u8
};

pub const OptimizerMessage = struct {
    ID: ?[]const u8,
    PluginName: []const u8,
    Text: []const u8,
    Location: ?BuildResultFileLocation,
    Notes: ?[]struct {
        Text: []const u8,
        Location: ?BuildResultFileLocation
    },
    Detail: ?u8 = null
};

pub const BuildResult = struct {
    Status: i8,
    Data: ?[]OptimizerMessage,
    Metadata: ?[]const u8
};

pub const OptimizeResult = struct {
    status: enum { Success, Failure, Warning },
    errors: []OptimizerMessage = &.{},
    warnings: []OptimizerMessage = &.{},
    inputs: [][]const u8 = &.{},
    meta: struct {
        bundleSize: i64 = 0
    },
    buildResult: BuildResult
};

// Optimizes a module in-place, and places it on disk to a temporary location
// Module must be pure
pub fn optimizePureModuleToDisk(allocator: std.mem.Allocator, module: []const u8, entry: []const u8, outDir: []const u8) !void {
    const modulePath = try std.mem.concat(allocator, u8, &.{outDir, "/node_modules/", module});

    // Make module path
    try std.fs.cwd().makePath(modulePath);

    // Optimize module
    var result: *OptimizeResult = try optimize(allocator, entry, try std.mem.concat(allocator, u8, &.{modulePath, "/index.js"}), "cjs", "");

    if(result.status != .Success and lto.checkAllowedDynamicModule(module) == false) {
        return error.FailedOptimizePureModule;
    }
}

// Copies a module to another location on disk
pub fn copyModuleToDisk(allocator: std.mem.Allocator, root: []const u8, module: []const u8, outDir: []const u8) !void {
    const modulePath = try std.mem.concat(allocator, u8, &.{outDir, "/node_modules/", module});
    const origPath = try std.mem.concat(allocator, u8, &.{root, "/node_modules/", module});

    // Make module path
    try std.fs.cwd().makePath(modulePath);

    var dir = try std.fs.openIterableDirAbsolute(origPath, .{});
    defer dir.close();
    var walker = try dir.walk(allocator);

    walkerLoop: while (try walker.next()) |entry| {
        // Ignore files/folder that are excluded
        for(ModuleCopyExcludes[0..ModuleCopyExcludes.len]) |glob| { if(analyzer.globMatch(glob, entry.path)) continue :walkerLoop; }

        if(entry.kind == .Directory) {
            try std.fs.makeDirAbsolute(try std.mem.concat(allocator, u8, &.{modulePath, "/", entry.path}));
        }else {
            try std.fs.copyFileAbsolute(try std.mem.concat(allocator, u8, &.{origPath, "/", entry.path}), try std.mem.concat(allocator, u8, &.{modulePath, "/", entry.path}), .{});
        }
    }
}

// Performs optimization on an entry point recursively
pub fn optimize(allocator: std.mem.Allocator, entry: []const u8, out: []const u8, format: []const u8, externals: []u8) !*OptimizeResult {

    const entrySentinel = try std.mem.concatWithSentinel(allocator, u8, &.{entry}, 0); 
    const outSentinel = try std.mem.concatWithSentinel(allocator, u8, &.{out}, 0);
    const formatSentinel = try std.mem.concatWithSentinel(allocator, u8, &.{format}, 0);

    const resultPtr = boptimizer.build(entrySentinel.ptr, outSentinel.ptr, formatSentinel.ptr, externals.ptr);
    const result: []u8 = resultPtr[0..std.mem.indexOfSentinel(u8, 0, resultPtr)];
    
    // Get wrapper build result
    const buildResult: BuildResult = x: {
        var stream = json.TokenStream.init(result);
        const res = json.parse(BuildResult, &stream, .{.allocator = allocator, .ignore_unknown_fields = true});
        break :x res catch |e| {
            return e;
        };
    };

    // Create optimization result
    var optimizeResult: *OptimizeResult = try allocator.create(OptimizeResult);
    optimizeResult.status = switch (buildResult.Status) {
        -1 => .Failure,
        0 => .Warning,
        1 => .Success,
        else => return error.UnknownOptimizeStatus
    };

    if(optimizeResult.status == .Warning) { optimizeResult.warnings = buildResult.Data.?; }
    else if(optimizeResult.status == .Failure) {
        optimizeResult.errors = buildResult.Data.?;
        return optimizeResult;
    }

    // Parse meta JSON
    var parser = json.Parser.init(allocator, false);
    var tree = try parser.parse(buildResult.Metadata.?);

    var outputs = tree.root.Object.get("outputs");
    var outputsIterator = outputs.?.Object.iterator();
    var outputBasename = std.fs.path.basename(out);

    // Get output bundle size in bytes
    while(outputsIterator.next()) |output| {
        if(std.mem.eql(u8, std.fs.path.basename(output.key_ptr.*), outputBasename)) {
            optimizeResult.meta.bundleSize = outputs.?.Object.get(output.key_ptr.*).?.Object.get("bytes").?.Integer;
            break;
        }
    }

    // Parse list of input sources
    var inputsObj = tree.root.Object.get("inputs");
    var iterator = inputsObj.?.Object.iterator();

    if(inputsObj == null or inputsObj.?.Object.count() == 0) {
        optimizeResult.inputs = &.{};
    }else {
        var inputsArrayList = std.ArrayList([]const u8).init(allocator);
        while(iterator.next()) |item| {
            try inputsArrayList.append(item.key_ptr.*);
        }

        optimizeResult.inputs = try inputsArrayList.toOwnedSlice();
    }

    // Save struct so we can free it later
    optimizeResult.buildResult = buildResult;

    return optimizeResult;

}
