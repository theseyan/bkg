// bkg CLI
const std = @import("std");
const clap = @import("clap");
const compiler = @import("compiler.zig");
const knownFolders = @import("known-folders");
const debug = std.debug;
const io = std.io;

// Path to project directory for archiving
var projectDirectory = undefined;

// Path to temporary directory used as cache
const tempDir = "/tmp";

// Path to bun binary to package
var bun = "/home/theseyan/.bun/bin/bun";

// Path to bkg runtime executable
var targetExe = "/home/theseyan/Zig/bkg/bkg_runtime";

// Initializes CLI environment
pub fn init() anyerror!void {

    // Parameters & head strings
    const head = 
        \\Usage: bkg [options] <ProjectDirectory>
        \\
        \\Options:
    ;
    const paramsStr = 
        \\  -h, --help             Display this help message.
        \\  -v, --version          Display bkg version.
        \\  -t, --target <str>     Target architecture to build for (default is Host)
        \\  -o, --output <str>     Output file name
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
        std.debug.print("{s}\n", .{res.positionals[0]});
    }
    // Parse other CLI flags
    else {
        // Parse params
        if (res.args.help) {
            debug.print("{s}\n{s}\n", .{head, paramsStr});
        }
        else if (res.args.version) {
            debug.print("0.0.1\n", .{});
        }
        // No param provided, display help
        else {
            debug.print("{s}\n{s}\n", .{head, paramsStr});
        }
    }

}