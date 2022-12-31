// Configuration manager
const std = @import("std");
const json = std.json;

// Configuration struct
pub const Config = struct {
    entry: []const u8 = "index.js",     // Entrypoint of the application
    debug: bool = false,                // Toggles debug logs at runtime
    lto: ?struct {                      // Link-Time Optimization
        format: []const u8 = "cjs",     // "cjs" or "esm"
        includes: [][]const u8 = &.{},  // Globs of file paths to package as assets into the binary
    } = null
};

// Default configuration JSON
// Injected automatically if no bkg.config.json was provided
pub const defaultConfig: Config = .{
    .entry = "index.js",
    .debug = false,
    .lto = null
};

// Stores the configuration
var config: Config = undefined;

// Loads and parses config JSON file
pub fn load(allocator: std.mem.Allocator, path: ?[]const u8, buffer: ?[]u8) !void {

    var buf: []u8 = undefined;

    if(path != null) {
        // Open config.json
        var file = try std.fs.openFileAbsolute(path.?, .{});
        defer file.close();

        // Read into buffer
        // Config file should not exceed 4 KiB
        buf = try file.readToEndAlloc(allocator, 4 * 1024);
    }else if(buffer != null) {
        buf = buffer.?;
    }

    // Parse the JSON payload and store the struct
    config = x: {
        var stream = json.TokenStream.init(buf);
        const res = json.parse(Config, &stream, .{.allocator = allocator, .ignore_unknown_fields = true});
        break :x res catch |e| {
            return e;
        };
    };

}

// Attempt to load configuration from disk
// If not, load defaults
pub fn tryLoadConfig(allocator: std.mem.Allocator, path: []const u8) !void {
    
    load(allocator, path, null) catch |e| switch(e) {
        error.FileNotFound => {
            var configObj = try allocator.create(Config);
            configObj.* = defaultConfig;
            config = configObj.*;
            return;
        },
        else => return e
    };

}

// Returns a pointer to the loaded configuration
pub fn get() *Config {
    return &config;
}