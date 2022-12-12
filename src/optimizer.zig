// Performs bundling, minification and optimization on Javascript sources

const std = @import("std");
const boptimizer = @import("translated/boptimizer.zig");
const json = std.json;

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
    errors: []OptimizerMessage = .{},
    warnings: []OptimizerMessage = .{},
    inputs: [][]const u8 = .{},
    meta: struct {
        bundleSize: i64 = 0
    }
};

// Performs optimization on an entry point recursively
pub fn optimize(allocator: std.mem.Allocator, entry: []const u8, out: []const u8, externals: []const u8) !*OptimizeResult {

    const resultPtr = boptimizer.build(entry.ptr, out.ptr, externals.ptr);
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

    // Get output bundle size in bytes
    var outputs = tree.root.Object.get("outputs");
    optimizeResult.meta.bundleSize = outputs.?.Object.get(std.fs.path.basename(out)).?.Object.get("bytes").?.Integer;

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

        optimizeResult.inputs = inputsArrayList.toOwnedSlice();
    }

    std.debug.print("{s}\n", .{optimizeResult.inputs[0]});

    return error.Done;

}