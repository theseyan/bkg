// Manager for bun binaries
// Handles binaries for multiple architectures and their versions
const std = @import("std");
const json = std.json;
const cURL = @import("translated/libcurl.zig");
const knownFolders = @import("known-folders");
const zip = @import("translated/libzip.zig");

// GitHub API URL for fetching latest Bun release
const bunLatestAPI = "https://api.github.com/repos/oven-sh/bun/releases/latest";

// Holds the allocator
var vmAllocator: *const std.mem.Allocator = undefined;

// We only need tag_name from API JSON response
pub const APIReleaseTag = struct{
    tag_name: []const u8
};

// Initialize Version Manager
// Inits cURL, makes sure .bkg directory exists
pub fn init(allocator: std.mem.Allocator) anyerror!void {

    // .bkg directory present in home directory
    const homeDir = (try knownFolders.getPath(vmAllocator.*, knownFolders.KnownFolder.home)) orelse @panic("Failed to get path to home directory.");
    const bkgDir = try std.mem.concat(vmAllocator.*, u8, &.{homeDir, "/.bkg"});

    // Check if bkg root exists
    _ = std.fs.openDirAbsolute(bkgDir, .{}) catch |e| {
        if(e == error.FileNotFound) {
            // Create bkg root
            try std.fs.makeDirAbsolute(bkgDir);
        }
    };

    // Initialize cURL
    if (cURL.curl_global_init(cURL.CURL_GLOBAL_ALL) != cURL.CURLE_OK) return error.CURLGlobalInitFailed;

    // Save pointer to allocator
    vmAllocator = &allocator;

}

// De-initializes Version Manager
pub fn deinit() anyerror!void {

    cURL.curl_global_cleanup();

}

// Fetches the latest release tag from Bun's official GitHub repo
// example: bun-v0.1.7
pub fn getLatestBunVersion() anyerror![]const u8 {

    const handle = cURL.curl_easy_init() orelse return error.CURLHandleInitFailed;
    defer cURL.curl_easy_cleanup(handle);

    var response_buffer = std.ArrayList(u8).init(vmAllocator.*);
    defer response_buffer.deinit();

    // Set cURL options
    if (cURL.curl_easy_setopt(handle, cURL.CURLOPT_URL, bunLatestAPI) != cURL.CURLE_OK) return error.CouldNotSetURL;
    if (cURL.curl_easy_setopt(handle, cURL.CURLOPT_USERAGENT, "theseyan/bkg") != cURL.CURLE_OK) return error.CouldNotSetUserAgent;

    // Set up callbacks
    if (cURL.curl_easy_setopt(handle, cURL.CURLOPT_WRITEFUNCTION, curlWriteToArrayListCallback) != cURL.CURLE_OK) return error.CouldNotSetWriteCallback;
    if (cURL.curl_easy_setopt(handle, cURL.CURLOPT_WRITEDATA, &response_buffer) != cURL.CURLE_OK) return error.CouldNotSetWriteCallback;

    // Execute HTTP request
    if (cURL.curl_easy_perform(handle) != cURL.CURLE_OK)
        return error.FailedToPerformRequest;

    // Parse JSON
    var config: APIReleaseTag = x: {
        var stream = json.TokenStream.init(response_buffer.items);
        const res = json.parse(APIReleaseTag, &stream, .{.allocator = vmAllocator.*, .ignore_unknown_fields = true});
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
pub fn downloadBun(version: []const u8, arch: []const u8) anyerror!void {

    std.debug.print("Downloading {s} for target {s}...\n", .{version, arch});

    // Construct URL to bun release
    const postfix = try getBunTargetString(arch);
    var releaseUrl = try std.mem.concat(vmAllocator.*, u8, &.{"https://github.com/oven-sh/bun/releases/download/", version, "/bun-", postfix, ".zip"});
    var releaseUrlZ = try vmAllocator.*.dupeZ(u8, releaseUrl);
    defer vmAllocator.*.free(releaseUrlZ);

    const homeDir = (try knownFolders.getPath(vmAllocator.*, knownFolders.KnownFolder.home)) orelse @panic("Failed to get path to home directory.");
    const runtimeDir = try std.mem.concatWithSentinel(vmAllocator.*, u8, &.{homeDir, "/.bkg/runtime"}, 0);

    // Formatted as {tag}-{target}/bun-{target}/bun
    // example: bun-v0.1.8-linux-x64/bun-x64-linux/bun
    const bunPath = try std.mem.concatWithSentinel(vmAllocator.*, u8, &.{homeDir, "/.bkg/runtime/", version, "-", postfix, "/bun-", postfix, "/bun"}, 0);
    const bunZipPath = try std.mem.concatWithSentinel(vmAllocator.*, u8, &.{homeDir, "/.bkg/runtime/", version, "-", postfix, ".zip"}, 0);
    const extractDir = try std.mem.concatWithSentinel(vmAllocator.*, u8, &.{runtimeDir, "/", version, "-", postfix}, 0);

    // Create /runtime directory if it doesn't already exist
    _ = std.fs.openDirAbsolute(runtimeDir, .{}) catch |e| {
        if(e == error.FileNotFound) try std.fs.makeDirAbsolute(runtimeDir);
    };

    // Check if the binary already exists
    const bin: ?std.fs.File = std.fs.openFileAbsolute(bunPath, .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return,
    };

    // Return if it already exists
    if (bin) |f| {
        f.close();
        std.debug.print("Runtime already exists, skipping\n", .{});
        return;
    }

    // Get handle to cURL
    const handle = cURL.curl_easy_init() orelse return error.CURLHandleInitFailed;
    defer cURL.curl_easy_cleanup(handle);

    // Allocate buffer for downloading
    var response_buffer = std.ArrayList(u8).init(vmAllocator.*);
    defer response_buffer.deinit();
    
    var headersList: ?*cURL.curl_slist = null;
    defer cURL.curl_slist_free_all(headersList);
    headersList = cURL.curl_slist_append(headersList, "Accept: application/octet-stream");

    // Set cURL options
    if (cURL.curl_easy_setopt(handle, cURL.CURLOPT_URL, releaseUrlZ.ptr) != cURL.CURLE_OK) return error.CouldNotSetURL;
    if (cURL.curl_easy_setopt(handle, cURL.CURLOPT_HTTPHEADER, headersList) != cURL.CURLE_OK) return error.CouldNotSetAcceptEncoding;
    if (cURL.curl_easy_setopt(handle, cURL.CURLOPT_USERAGENT, "theseyan/bkg") != cURL.CURLE_OK) return error.CouldNotSetUserAgent;
    if (cURL.curl_easy_setopt(handle, cURL.CURLOPT_FOLLOWLOCATION, @intCast(c_long, 1)) != cURL.CURLE_OK) return error.CouldNotSetFollowLocation;

    // Set up callbacks
    if (cURL.curl_easy_setopt(handle, cURL.CURLOPT_WRITEFUNCTION, curlWriteToArrayListCallback) != cURL.CURLE_OK) return error.CouldNotSetWriteCallback;
    if (cURL.curl_easy_setopt(handle, cURL.CURLOPT_WRITEDATA, &response_buffer) != cURL.CURLE_OK) return error.CouldNotSetWriteCallback;

    // Execute HTTP request
    if (cURL.curl_easy_perform(handle) != cURL.CURLE_OK) return error.FailedToPerformRequest;

    // Create file on disk
    var file = try std.fs.createFileAbsolute(bunZipPath, .{});
    defer file.close();

    // Write to file
    var written = try file.write(response_buffer.items);
    std.debug.print("Downloaded {any} bytes to disk\n", .{written});
    std.debug.print("Extracting to {s}...\n", .{extractDir});

    _ = runtimeDir;
    _ = bunPath;

    // Extract the zip archive
    var arg: c_int = 2;
    _ = zip.zip_extract(bunZipPath.ptr, extractDir.ptr, zip_extract_entry, &arg);

    // Delete the archive since it's no longer needed
    try std.fs.deleteFileAbsolute(bunZipPath);

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
    }else if(std.mem.eql(u8, target, "x86_64-darwin")) {
        return "darwin-x64";
    }else if(std.mem.eql(u8, target, "aarch64-darwin")) {
        return "darwin-aarch64";
    }else {
        return error.UnknownTarget;
    }

}

// Callback required by cURL to write to a Zig ArrayList
fn curlWriteToArrayListCallback(data: *anyopaque, size: c_uint, nmemb: c_uint, user_data: *anyopaque) callconv(.C) c_uint {

    var buffer = @intToPtr(*std.ArrayList(u8), @ptrToInt(user_data));
    var typed_data = @intToPtr([*]u8, @ptrToInt(data));
    buffer.appendSlice(typed_data[0 .. nmemb * size]) catch return 0;
    return nmemb * size;

}