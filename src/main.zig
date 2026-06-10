const std = @import("std");
const config = @import("config.zig");
const cli = @import("adapters/cli.zig");
const HttpClient = @import("adapters/http_client.zig").HttpClient;
const FsIndexCache = @import("adapters/fs_index_cache.zig").FsIndexCache;
const CachedIndexCatalog = @import("adapters/cached_catalog.zig").CachedIndexCatalog;
const update_index = @import("app/update_index.zig");
const get_info = @import("app/get_info.zig");
const search = @import("app/search.zig");
const resolve_deps = @import("app/resolve_deps.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const a = init.arena.allocator();

    const home = init.environ_map.get("HOME") orelse return error.NoHome;
    const prefix_override = init.environ_map.get("METALBREW_PREFIX");
    const paths = try config.Paths.resolve(a, home, prefix_override);

    // Build argv (skip program name).
    var arg_list: std.ArrayList([]const u8) = .empty;
    var ait = std.process.Args.Iterator.init(init.minimal.args);
    _ = ait.next();
    while (ait.next()) |arg| try arg_list.append(a, arg);
    const argv = try arg_list.toOwnedSlice(a);
    const cmd = cli.Command.parse(argv);

    var out_buf: [4096]u8 = undefined;
    var out_fw: std.Io.File.Writer = .init(.stdout(), io, &out_buf);
    const w = &out_fw.interface;
    defer w.flush() catch {};

    switch (cmd) {
        .help, .unknown => try printHelp(w),
        .update => {
            const http = try HttpClient.init(init.gpa);
            defer http.deinit();
            const cache_dir = try std.Io.Dir.cwd().createDirPathOpen(io, paths.cache_api, .{});
            var cache = FsIndexCache{ .io = io, .dir = cache_dir };
            const n = try update_index.run(a, http, cache.port(), update_index.INDEX_URL);
            try w.print("Updated index: {d} bytes -> {s}/formula.json\n", .{ n, paths.cache_api });
        },
        .info => |name| {
            var cat = (try loadCachedCatalog(init, paths)) orelse {
                try w.writeAll("No index. Run `metalbrew update` first.\n");
                return;
            };
            defer cat.deinit();
            const f = get_info.run(a, cat.port(), name) catch |e| switch (e) {
                error.NotFound => {
                    try w.print("No formula named '{s}'. Try `metalbrew update`.\n", .{name});
                    return;
                },
                else => return e,
            };
            try w.print("{s}: {s}\n{s}\n", .{ f.name, f.version.raw, f.desc });
            if (f.dependencies.len > 0) {
                try w.writeAll("Dependencies: ");
                for (f.dependencies, 0..) |d, i| {
                    if (i > 0) try w.writeAll(", ");
                    try w.writeAll(d.name);
                }
                try w.writeAll("\n");
            }
        },
        .search => |q| {
            var cat = (try loadCachedCatalog(init, paths)) orelse {
                try w.writeAll("No index. Run `metalbrew update` first.\n");
                return;
            };
            defer cat.deinit();
            const hits = try search.run(a, cat.port(), q);
            for (hits) |name| try w.print("{s}\n", .{name});
        },
        .deps => |name| {
            var cat = (try loadCachedCatalog(init, paths)) orelse {
                try w.writeAll("No index. Run `metalbrew update` first.\n");
                return;
            };
            defer cat.deinit();
            const order = try resolve_deps.run(a, cat.port(), name);
            const deps = if (order.len > 0) order[0 .. order.len - 1] else order;
            for (deps) |d| try w.print("{s}\n", .{d});
        },
    }
}

fn loadCachedCatalog(init: std.process.Init, paths: config.Paths) !?CachedIndexCatalog {
    const a = init.arena.allocator();
    const cache_dir = std.Io.Dir.cwd().createDirPathOpen(init.io, paths.cache_api, .{}) catch return null;
    var cache = FsIndexCache{ .io = init.io, .dir = cache_dir };
    const bytes = (try cache.port().read(a)) orelse return null;
    return try CachedIndexCatalog.init(init.gpa, bytes);
}

fn printHelp(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\metalbrew — read-only spine (M1)
        \\
        \\Usage:
        \\  metalbrew update            Refresh the formula index
        \\  metalbrew info <formula>    Show formula metadata
        \\  metalbrew search <query>    Search formula names
        \\  metalbrew deps <formula>    Show transitive runtime dependencies
        \\
    );
}
