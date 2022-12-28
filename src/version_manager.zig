// Manager for bun binaries
// Handles binaries for multiple architectures and their versions
const std = @import("std");
const json = std.json;
const knownFolders = @import("known-folders");
const zip = @import("translated/libzip.zig");
const zfetch = @import("zfetch");
const debug = @import("debug.zig");

// GitHub API URL for fetching latest Bun & bkg releases
const bunLatestAPI = "https://api.github.com/repos/oven-sh/bun/releases/latest";
const bkgLatestAPI = "https://api.github.com/repos/theseyan/bkg/releases/latest";

// Holds the allocator
var vmAllocator: std.mem.Allocator = undefined;

// We only need tag_name from API JSON response
pub const APIReleaseTag = struct{
    tag_name: []const u8
};

// Initialize Version Manager
// Inits zfetch, makes sure .bkg directory exists
pub fn init(allocator: std.mem.Allocator) anyerror!void {

    // Save pointer to allocator
    vmAllocator = allocator;

    // .bkg directory present in home directory
    const homeDir = (try knownFolders.getPath(vmAllocator, knownFolders.KnownFolder.home)) orelse @panic("Failed to get path to home directory.");
    const bkgDir = try std.mem.concat(vmAllocator, u8, &.{homeDir, "/.bkg"});

    // Check if bkg root exists
    _ = std.fs.openDirAbsolute(bkgDir, .{}) catch |e| {
        if(e == error.FileNotFound) {
            // Create bkg root
            try std.fs.makeDirAbsolute(bkgDir);
        }
    };

    // Initialize zfetch
    try zfetch.init();

}

// De-initializes Version Manager
pub fn deinit() void {

    zfetch.deinit();

}

// Custom downloader that respects HTTP 3xx redirects
pub fn download(url: []const u8, path: []const u8) !usize {

    // Init headers and request
    var headers = zfetch.Headers.init(vmAllocator);
    defer headers.deinit();
    var req = try zfetch.Request.init(vmAllocator, url, null);
    defer req.deinit();

    // Perform request
    try headers.appendValue("Accept", "application/octet-stream");
    try headers.appendValue("User-Agent", "theseyan/bkg");
    try req.do(.GET, headers, null);

    // Follow 3xx redirects
    if (req.status.code > 300 and req.status.code < 400) {
        var locationHeader = req.headers.search("Location");
        return download(locationHeader.?.value, path);
    }
    // If status is neither 200 or 3xx
    else if(req.status.code != 200) {
        return error.DownloadFailed;
    }

    // Create file on disk
    const file = try std.fs.createFileAbsolute(path, .{});
    const writer = file.writer();
    const reader = req.reader();

    // Write download buffer to file
    var size: usize = 0;
    var buf: [65535]u8 = undefined;
    while (true) {
        const read = try reader.read(&buf);
        if (read == 0) break;
        size += read;
        try writer.writeAll(buf[0..read]);
    }

    return size;

}

// Custom fetch that respects 3xx redirects
// Returns a buffer that must be freed manually
pub fn fetch(url: []const u8) ![]const u8 {

    // Init headers and request
    var headers = zfetch.Headers.init(vmAllocator);
    defer headers.deinit();
    var req = try zfetch.Request.init(vmAllocator, url, null);
    defer req.deinit();

    // Perform request
    try headers.appendValue("Accept", "*/*");
    try headers.appendValue("User-Agent", "theseyan/bkg");
    try req.do(.GET, headers, null);

    // Follow 3xx redirects
    if (req.status.code > 300 and req.status.code < 400) {
        var locationHeader = req.headers.search("Location");
        return fetch(locationHeader.?.value);
    }
    // If status is neither 200 or 3xx
    else if(req.status.code != 200) {
        return error.FetchFailed;
    }

    // Read response buffer
    const reader = req.reader();
    const buffer = try reader.readAllAlloc(vmAllocator, 8 * 1024 * 1024); // Response body should not exceed 8 MiB

    return buffer;

}

// Fetches the latest release tag from Bun's official GitHub repo
// example: bun-v0.1.7
pub fn getLatestBunVersion() anyerror![]const u8 {

    var response_buffer = try fetch(bunLatestAPI);
    defer vmAllocator.free(response_buffer);

    // Parse JSON
    var config: APIReleaseTag = x: {
        var stream = json.TokenStream.init(response_buffer);
        const res = json.parse(APIReleaseTag, &stream, .{.allocator = vmAllocator, .ignore_unknown_fields = true});
        break :x res catch |e| {
            std.debug.print("Error while parsing JSON: {}\n", .{e});
            return error.ErrorParsingJSON;
        };
    };

    return config.tag_name;

}

// Downloads Bun binary for a given version and platform
// Returns immediately if the binary already exists
// example: bun-v0.1.8, aarch64-linux
pub fn downloadBun(version: []const u8, arch: []const u8, specifier: ?[]const u8) anyerror![]const u8 {

    std.debug.print("Downloading {s} for target {s}...\n", .{version, arch});

    // Construct URL to bun release
    const postfix = if(specifier == null) try getBunTargetString(arch) else try std.mem.concat(vmAllocator, u8, &.{try getBunTargetString(arch), "-", specifier.?});
    var releaseUrl = try std.mem.concat(vmAllocator, u8, &.{"https://github.com/oven-sh/bun/releases/download/", version, "/bun-", postfix, ".zip"});

    const homeDir = (try knownFolders.getPath(vmAllocator, knownFolders.KnownFolder.home)) orelse @panic("Failed to get path to home directory.");
    const runtimeDir = try std.mem.concat(vmAllocator, u8, &.{homeDir, "/.bkg/runtime"});

    // Formatted as {tag}-{target}/bun-{target}/bun
    // example: bun-v0.1.8-linux-x64/bun-x64-linux/bun
    const bunPath = try std.mem.concat(vmAllocator, u8, &.{homeDir, "/.bkg/runtime/", version, "-", postfix, "/bun-", postfix, "/bun"});
    const bunZipPath = try std.mem.concatWithSentinel(vmAllocator, u8, &.{homeDir, "/.bkg/runtime/", version, "-", postfix, ".zip"}, 0);
    const extractDir = try std.mem.concatWithSentinel(vmAllocator, u8, &.{runtimeDir, "/", version, "-", postfix}, 0);

    // Create /runtime directory if it doesn't already exist
    _ = std.fs.openDirAbsolute(runtimeDir, .{}) catch |e| {
        if(e == error.FileNotFound) try std.fs.makeDirAbsolute(runtimeDir);
    };

    // Check if the binary already exists
    const bin: ?std.fs.File = std.fs.openFileAbsolute(bunPath, .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };

    // Return if it already exists
    if (bin) |f| {
        f.close();
        std.debug.print("Runtime already exists, skipping\n", .{});
        return bunPath;
    }

    // Write to file
    var written = try download(releaseUrl, bunZipPath);
    std.debug.print("Downloaded {any} bytes to disk\n", .{written});
    std.debug.print("Extracting to {s}...\n", .{extractDir});

    // Extract the zip archive
    var arg: c_int = 2;
    _ = zip.zip_extract(bunZipPath.ptr, extractDir.ptr, zip_extract_entry, &arg);

    // Delete the archive since it's no longer needed
    try std.fs.deleteFileAbsolute(bunZipPath);

    return bunPath;

}

// Fetches the latest release tag from bkg's GitHub repo
// example: v0.0.1
pub fn getLatestBkgVersion() anyerror![]const u8 {
    
    var response_buffer = try fetch(bkgLatestAPI);
    defer vmAllocator.free(response_buffer);

    // Parse JSON
    var config: APIReleaseTag = x: {
        var stream = json.TokenStream.init(response_buffer);
        const res = json.parse(APIReleaseTag, &stream, .{.allocator = vmAllocator, .ignore_unknown_fields = true});
        break :x res catch |e| {
            std.debug.print("Error while parsing JSON: {}\n", .{e});
            return error.ErrorParsingJSON;
        };
    };

    return config.tag_name;

}

// Downloads bkg runtime binary for a given version and platform
// Returns immediately if the binary already exists
// example: v0.0.1, aarch64-linux
pub fn downloadRuntime(version: []const u8, arch: []const u8) anyerror![]const u8 {

    const homePath = (try knownFolders.getPath(vmAllocator, knownFolders.KnownFolder.home)) orelse return error.CannotGetHomePath;
    const runtimePath = try std.mem.concat(vmAllocator, u8, &.{homePath, "/.bkg/bkg_runtime/", arch, "/bkg_runtime-", version});
    const runtimeDir = try std.mem.concat(vmAllocator, u8, &.{homePath, "/.bkg/bkg_runtime"});

    std.debug.print("Downloading bkg runtime {s} for target {s}...\n", .{version, arch});

    // Construct URL to download release
    var releaseUrl = try std.mem.concat(vmAllocator, u8, &.{"https://github.com/theseyan/bkg/releases/download/", version, "/bkg_runtime-", version, "-", arch});

    // Create /bkg_runtime and {arch} directory if it doesn't already exist
    _ = std.fs.openDirAbsolute(runtimeDir, .{}) catch |e| {
        if(e == error.FileNotFound) try std.fs.makeDirAbsolute(runtimeDir);
    };
    _ = std.fs.openDirAbsolute(try std.mem.concat(vmAllocator, u8, &.{runtimeDir, "/", arch}), .{}) catch |e| {
        if(e == error.FileNotFound) try std.fs.makeDirAbsolute(try std.mem.concat(vmAllocator, u8, &.{runtimeDir, "/", arch}));
    };

    // Check if the binary already exists
    const bin: ?std.fs.File = std.fs.openFileAbsolute(runtimePath, .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };

    // Return if it already exists
    if (bin) |f| {
        f.close();
        std.debug.print("bkg runtime already exists, skipping\n", .{});
        return runtimePath;
    }

    // Download the file
    const written = try download(releaseUrl, runtimePath);
    std.debug.print("Downloaded {any} bytes to disk\n", .{written});

    return runtimePath;

}

// Placeholder callback for zip_extract
fn zip_extract_entry(_: [*c]const u8, _: ?*anyopaque) callconv(.C) c_int {
    return 0;
}

// Returns a Bun target string from a standard one
pub fn getBunTargetString(target: []const u8) ![]const u8 {

    if(std.mem.eql(u8, target, "x86_64-linux")) {
        return "linux-x64";
    }else if(std.mem.eql(u8, target, "aarch64-linux")) {
        return "linux-aarch64";
    }else if(std.mem.eql(u8, target, "x86_64-macos")) {
        return "darwin-x64";
    }else if(std.mem.eql(u8, target, "aarch64-macos")) {
        return "darwin-aarch64";
    }else {
        return error.UnknownTarget;
    }

}