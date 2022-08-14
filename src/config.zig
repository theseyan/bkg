// Configuration manager
const std = @import("std");
const json = std.json;

// Configuration struct
pub const Config = struct {
    entry: []const u8
};

// Default configuration JSON
// Injected automatically if no bkg.config.json was provided
pub const defaultConfig: []const u8 = 
    \\{
    \\  "entry": "index.js"
    \\}
;

// Stores the configuration
var config: Config = undefined;

// Loads and parses config JSON file
pub fn load(allocator: std.mem.Allocator, path: []const u8) !void {

    // Open config.json
    var file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    // Read into buffer
    // Config file should not exceed 4 KiB
    const buf: []const u8 = try file.readToEndAlloc(allocator, 4 * 1024);

    // Parse the JSON payload and store the struct
    config = x: {
        var stream = json.TokenStream.init(buf);
        const res = json.parse(Config, &stream, .{.allocator = allocator});
        break :x res catch |e| {
            return e;
        };
    };

}

// Returns a pointer to the loaded configuration
pub fn get() *Config {
    return &config;
}