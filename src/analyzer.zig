// Analyzes sources and node_modules to find and collect native/pure modules
// Used in conjunction with the optimizer to enable link-time optimizations
const std = @import("std");

// TODO: This may be incomplete
pub const NativeExtensions = [_][]const u8{"*.node", "*.so", "*.so.*", "*.dll", "*.exe", "*.dylib"};

const Module = struct {
    type: []const u8,               // "native" or "pure"
    path: []const u8,               // import-able path of the module
    name: []const u8,               // name of the module
    main: []const u8,               // Main entrypoint of package
    deps: []*const Module                 // list of dependencies
};

const PackageJSON = struct {
    main: []const u8 = "index.js",
    deps: [][]const u8,
    name: []const u8
};

// Central repository of all modules
var modules: std.ArrayList(Module) = undefined;

pub fn init(allocator: std.mem.Allocator) !void {
    modules = std.ArrayList(Module).init(allocator);
}

// Analyzer
pub fn analyze(allocator: std.mem.Allocator, root: []const u8) !void {
    var dir = try std.fs.openIterableDirAbsolute(root, .{});
    defer dir.close();
    var walker = try dir.walk(allocator);

    // Register all packages without dependencies
    while (try walker.next()) |entry| {
        const basename = std.fs.path.basename(entry.path);

        if(entry.kind != .Directory and std.mem.eql(u8, basename, "package.json")) {
            const path = entry.path[0..(entry.path.len - basename.len - 1)];
            const parsed = try parsePackage(allocator, root, entry.path);
            const name = if (parsed.name.len == 0) std.fs.path.basename(path) else parsed.name;
            const modtype = try analyzeModule(allocator, try std.mem.concat(allocator, u8, &.{root, "/", path}));
            var deps = std.ArrayList(*const Module).init(allocator);

            // Register the module to store
            try modules.append(Module{
                .type = modtype,
                .path = try allocator.dupe(u8, path),
                .name = try allocator.dupe(u8, name),
                .main = try allocator.dupe(u8, parsed.main),
                .deps = deps.toOwnedSlice()
            });
        }
    }
    walker.deinit();

    // Parse every registered module and populate its dependencies
    for(modules.items[0..modules.items.len]) |module, i| {
        const parsed = try parsePackage(allocator, root, try std.mem.concat(allocator, u8, &.{module.path, "/package.json"}));
        var depsArrayList = std.ArrayList(*const Module).init(allocator);
        
        for(parsed.deps[0..parsed.deps.len]) |dep| {
            var depPtr = try getModulePtr(dep);
            try depsArrayList.append(depPtr);
        }

        const replaceModule = Module{
            .type = module.type,
            .path = module.path,
            .name = module.name,
            .main = module.main,
            .deps = depsArrayList.toOwnedSlice()
        };

        try modules.replaceRange(i, 1, &.{replaceModule});
    }
}

// Gets a pointer to a module stored in repository
pub fn getModulePtr(path: []const u8) !*const Module {
    for(modules.items[0..modules.items.len]) |module, i| {
        if(std.mem.eql(u8, module.path, path)) return &modules.items[i];
    }
    return error.ModuleNotFound;
}

// Analyzes a modules directory to find whether it is "native" or "pure"
pub fn analyzeModule(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var dir = try std.fs.openIterableDirAbsolute(path, .{});
    defer dir.close();
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if(entry.kind == .Directory) continue;
        const basename = std.fs.path.basename(entry.path);

        for(NativeExtensions[0..NativeExtensions.len]) |ext| {
            if(globMatch(ext, basename)) return "native";
        }
    }

    return "pure";
}

// Parses a modules package.json
pub fn parsePackage(allocator: std.mem.Allocator, root: []const u8, path: []const u8) !PackageJSON {
    // Open package.json
    var file = std.fs.openFileAbsolute(std.mem.concat(allocator, u8, &.{root, "/", path})  catch |e| @panic(@errorName(e)), .{}) catch |e| @panic(@errorName(e));
    defer file.close();

    // Read into buffer
    // package.json should not exceed 32 KiB
    const buf = file.readToEndAlloc(allocator, 32 * 1024) catch |e| @panic(@errorName(e));

    // Parse the JSON payload
    var parser = std.json.Parser.init(allocator, false);
    var tree = parser.parse(buf) catch |e| @panic(@errorName(e));

    var deps = tree.root.Object.get("dependencies");
    var main = tree.root.Object.get("main").?.String;
    var pkgName = tree.root.Object.get("name").?.String;
    var depsArray: [][]const u8 = undefined;
    var iterator = deps.?.Object.iterator();


    if(deps == null or deps.?.Object.count() == 0) {
        depsArray = &.{};
    }else {
        var depsArrayList = std.ArrayList([]const u8).init(allocator);
        
        while(iterator.next()) |entry| {
            try depsArrayList.append(entry.key_ptr.*);
        }

        depsArray = depsArrayList.toOwnedSlice();
    }

    return PackageJSON{
        .name = pkgName,
        .main = if(main.len == 0) "index.js" else main,
        .deps =  depsArray
    };
}

// Tests a path string against a glob
pub fn globMatch(pattern: []const u8, str: []const u8) bool {
    if (std.mem.eql(u8, pattern, "*")) return true;

    var i: usize = 0;
    var it = std.mem.tokenize(u8, pattern, "*");
    var exact_begin = pattern.len > 0 and pattern[0] != '*';

    while (it.next()) |substr| {
        if (std.mem.indexOf(u8, str[i..], substr)) |j| {
            if (exact_begin) {
                if (j != 0) return false;
                exact_begin = false;
            }

            i += j + substr.len;
        } else return false;
    }

    return if (pattern[pattern.len - 1] == '*') true else i == str.len;
}