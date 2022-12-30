// bkg CLI
const std = @import("std");
const clap = @import("clap");
const knownFolders = @import("known-folders");
const compiler = @import("compiler.zig");
const versionManager = @import("version_manager.zig");
const debug = std.debug;
const io = std.io;
const lto = @import("lto.zig");
const config = @import("config.zig");

// Initializes CLI environment
pub fn init(allocator: std.mem.Allocator) anyerror!void {

    // Parameters & head strings
    const head = 
        \\Usage: bkg [options] <ProjectDirectory>
        \\
        \\Options:
    ;
    const paramsStr = 
        \\  -o, --output <str>     Output file name
        \\  -i, --includes <str>   Comma-separated list of files to include into the binary
        \\  -t, --target <str>     Target architecture to build for (default is Host)
        \\  -b, --baseline         Use non-AVX2 (baseline) build of Bun for compatibility
        \\  --lto                  Enable Link-Time Optimizations (experimental)
        \\  --targets              Display list of supported targets
        \\  -h, --help             Display this help message.
        \\  -v, --version          Display bkg version.
        \\  -d, --debug            Enable debug logs at runtime
        \\  --runtime <str>        Path to custom Bun binary (not recommended)
        \\  <str>...
        \\
    ;
    const params = comptime clap.parseParamsComptime(paramsStr);

    // We use optional diagnostics
    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
    }) catch |err| {
        diag.report(io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();
    
    // <ProjectDirectory> is provided
    if(res.positionals.len > 0) {

        // Absolute path to input directory
        var project: []const u8 = try std.fs.realpathAlloc(allocator, res.positionals[0]);
        defer allocator.free(project);

        // Target string to build for
        // example: x86_64-linux
        var target: []const u8 = undefined;

        // Absolute output path of the resulting executable
        var output: []const u8 = undefined;

        // Whether to use a baseline build of Bun
        var baseline: ?[]const u8 = if (res.args.baseline) "baseline" else null;

        // Whether to enable debug mode
        var debugMode: bool = false;

        // TODO: Ability to use custom Bun binary
        if(res.args.runtime != null) {
            debug.print("Custom bun binary is not supported in this version, prebuilt will be used.\n", .{});
        }

        // Get build target
        if(res.args.target != null) {
            target = res.args.target.?;
            debug.print("Building for target {s}\n", .{res.args.target.?});
        }else {
            target = try compiler.getHostTargetString(allocator);
            debug.print("No target was specified, building for {s}\n", .{target});
        }

        if (res.args.baseline) debug.print("Using non-AVX2 (baseline) build of Bun...\n", .{});
        if (res.args.debug) {
            debugMode = true;
            debug.print("Building with Debug mode enabled...\n", .{});
        }

        // Get output path
        if(res.args.output != null) {
            var basename = std.fs.path.basename(res.args.output.?);
            var dirname = std.fs.path.dirname(res.args.output.?) orelse ".";
            output = try std.mem.concat(allocator, u8, &.{try std.fs.realpathAlloc(allocator, dirname), "/", basename});
        }else {
            var cwdPath = try std.fs.realpathAlloc(allocator, ".");
            defer allocator.free(cwdPath);
            output = try std.mem.concat(allocator, u8, &.{cwdPath, "/app"});
        }

        // Get configuration
        try config.tryLoadConfig(allocator, try std.mem.concat(allocator, u8, &.{project, "/bkg.config.json"}));

        // Whether LTO is enabled
        const isLTO = if(res.args.lto) true else if(config.get().lto != null) true else false;

        // List of globs to package as assets into the binary
        var includes: [][]const u8 = undefined;

        if(res.args.includes != null) {
            var iterator = std.mem.split(u8, res.args.includes.?, ",");
            var list = std.ArrayList([]const u8).init(allocator);
            while(iterator.next()) |glob| {
                try list.append(glob);
            }
            includes = try list.toOwnedSlice();
        }else {
            includes = config.get().lto.?.includes;
        }

        // Initialize version manager
        try versionManager.init(allocator);
        defer versionManager.deinit();

        // Make sure we have the latest Bun and bkg runtime for the target
        var runtimePath = try versionManager.downloadBun(try versionManager.getLatestBunVersion(), target, baseline);
        var bkgRuntimePath = try versionManager.downloadRuntime(try versionManager.getLatestBkgVersion(), target);

        // Initialize LTO
        if(isLTO) {
            try lto.init(allocator, project, includes);

            std.debug.print("Performing Link-Time Optimizations...\n", .{});
            project = try lto.LTO(config.get().entry, config.get().lto.?.format);
        }else {
            //std.debug.print("Skipping Link-Time Optimizations because it was disabled. It is highly recommended to enable LTO in production builds.\n", .{});
        }

        // Build the executable
        var out = try compiler.build(allocator, runtimePath, bkgRuntimePath, target, project, output, debugMode);

        // Clean up
        if(isLTO) {
            std.debug.print("Cleaning up...\n", .{});
            try lto.cleanup();
        }
        
        // Finish up
        std.debug.print("⚡ Built {s} for target {s}.\n", .{std.fs.path.basename(out), target});

    }
    // Parse other CLI flags
    else {
        // Parse params
        if (res.args.help) {
            debug.print("{s}\n{s}\n", .{head, paramsStr});
        }
        else if (res.args.version) {
            debug.print("0.0.4\n", .{});
        }
        else if (res.args.targets) {
            debug.print("x86_64-linux\naarch64-linux\nx86_64-macos\naarch64-macos\n", .{});
        }
        // No param provided, display help
        else {
            debug.print("{s}\n{s}\n", .{head, paramsStr});
        }
    }

}