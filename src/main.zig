const std = @import("std");
const config = @import("config.zig");
const cli = @import("adapters/cli.zig");
const HttpClient = @import("adapters/http_client.zig").HttpClient;
const FsIndexCache = @import("adapters/fs_index_cache.zig").FsIndexCache;
const CachedIndexCatalog = @import("adapters/cached_catalog.zig").CachedIndexCatalog;
const GhcrFetcher = @import("adapters/ghcr_fetcher.zig").GhcrFetcher;
const FsReceiptStore = @import("adapters/fs_receipts.zig").FsReceiptStore;
const os_tag = @import("adapters/os_tag.zig");
const progress = @import("adapters/progress.zig");
const update_index = @import("app/update_index.zig");
const get_info = @import("app/get_info.zig");
const search = @import("app/search.zig");
const resolve_deps = @import("app/resolve_deps.zig");
const install_app = @import("app/install.zig");
const list_app = @import("app/list.zig");
const uninstall_app = @import("app/uninstall.zig");
const upgrade_app = @import("app/upgrade.zig");

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
            var err_buf: [4096]u8 = undefined;
            var err_fw: std.Io.File.Writer = .init(.stderr(), io, &err_buf);
            const stderr_is_tty = std.Io.File.stderr().isTty(io) catch false;
            var bar = progress.Bar.init(&err_fw.interface, stderr_is_tty);
            bar.setLabel("index");
            const n = try update_index.run(a, http, cache.port(), update_index.INDEX_URL, &bar);
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
            const order = resolve_deps.run(a, cat.port(), name) catch |e| switch (e) {
                error.UnknownFormula => {
                    try w.print("No formula named '{s}'. Try `metalbrew update`.\n", .{name});
                    return;
                },
                error.CycleDetected => {
                    try w.print("Dependency cycle involving '{s}'.\n", .{name});
                    return;
                },
                else => return e,
            };
            const deps = if (order.len > 0) order[0 .. order.len - 1] else order;
            for (deps) |d| try w.print("{s}\n", .{d});
        },
        .install => |name| {
            var cat = (try loadCachedCatalog(init, paths)) orelse {
                try w.writeAll("No index. Run `metalbrew update` first.\n");
                return;
            };
            defer cat.deinit();

            const cellar_abs = try std.fs.path.join(a, &.{ paths.prefix, "Cellar" });
            const cellar_dir = try std.Io.Dir.cwd().createDirPathOpen(io, cellar_abs, .{});
            const receipts_abs = try std.fs.path.join(a, &.{ paths.prefix, "var", "metalbrew", "receipts" });
            const receipts_dir = try std.Io.Dir.cwd().createDirPathOpen(io, receipts_abs, .{});
            var receipts = FsReceiptStore{ .io = io, .dir = receipts_dir };

            const http = try HttpClient.init(init.gpa);
            defer http.deinit();
            var fetcher = GhcrFetcher{ .http = http };

            const tag = os_tag.detectArm64Tag(io, a) catch |e| switch (e) {
                error.UnsupportedMacOS => {
                    try w.writeAll("Unsupported macOS version (no arm64 bottle tag).\n");
                    return;
                },
                else => return e,
            };
            const tags = [_][]const u8{tag.text};

            const installer = install_app.Installer{
                .io = io,
                .allocator = a,
                .catalog = cat.port(),
                .fetcher = fetcher.port(),
                .receipts = receipts.port(),
                .cellar_dir = cellar_dir,
                .cellar_abs = cellar_abs,
                .prefix_abs = paths.prefix,
                .tags = &tags,
            };

            const newly = installer.install(name) catch |e| switch (e) {
                error.UnknownFormula => {
                    try w.print("No formula named '{s}'. Try `metalbrew update`.\n", .{name});
                    return;
                },
                error.NoBottleForPlatform => {
                    try w.print("No bottle for this platform ({s}) for '{s}'.\n", .{ tag.text, name });
                    return;
                },
                else => return e,
            };
            if (newly.len == 0) {
                try w.writeAll("Already installed.\n");
            } else {
                for (newly) |n| try w.print("Installed: {s}\n", .{n});
            }
        },
        .list => {
            const receipts_abs = try std.fs.path.join(a, &.{ paths.prefix, "var", "metalbrew", "receipts" });
            const receipts_dir = try std.Io.Dir.cwd().createDirPathOpen(io, receipts_abs, .{});
            var receipts = FsReceiptStore{ .io = io, .dir = receipts_dir };
            const all = try list_app.run(a, receipts.port());
            if (all.len == 0) {
                try w.writeAll("No packages installed.\n");
            } else {
                for (all) |r| try w.print("{s} {s}\n", .{ r.name, r.version });
            }
        },
        .uninstall => |name| {
            const cellar_abs = try std.fs.path.join(a, &.{ paths.prefix, "Cellar" });
            const cellar_dir = try std.Io.Dir.cwd().createDirPathOpen(io, cellar_abs, .{});
            const receipts_abs = try std.fs.path.join(a, &.{ paths.prefix, "var", "metalbrew", "receipts" });
            const receipts_dir = try std.Io.Dir.cwd().createDirPathOpen(io, receipts_abs, .{});
            var receipts = FsReceiptStore{ .io = io, .dir = receipts_dir };

            const uninstaller = uninstall_app.Uninstaller{
                .io = io,
                .allocator = a,
                .receipts = receipts.port(),
                .prefix_abs = paths.prefix,
                .cellar_dir = cellar_dir,
            };
            uninstaller.uninstall(name) catch |e| switch (e) {
                error.NotInstalled => {
                    try w.print("'{s}' is not installed.\n", .{name});
                    return;
                },
                else => return e,
            };
            try w.print("Uninstalled {s}.\n", .{name});
        },
        .upgrade => |only| {
            var cat = (try loadCachedCatalog(init, paths)) orelse {
                try w.writeAll("No index. Run `metalbrew update` first.\n");
                return;
            };
            defer cat.deinit();

            const cellar_abs = try std.fs.path.join(a, &.{ paths.prefix, "Cellar" });
            const cellar_dir = try std.Io.Dir.cwd().createDirPathOpen(io, cellar_abs, .{});
            const receipts_abs = try std.fs.path.join(a, &.{ paths.prefix, "var", "metalbrew", "receipts" });
            const receipts_dir = try std.Io.Dir.cwd().createDirPathOpen(io, receipts_abs, .{});
            var receipts = FsReceiptStore{ .io = io, .dir = receipts_dir };

            const plans = upgrade_app.plan(a, cat.port(), receipts.port(), only) catch |e| switch (e) {
                error.NotInstalled => {
                    try w.print("'{s}' is not installed.\n", .{only.?});
                    return;
                },
                error.UnknownFormula => {
                    try w.print("No formula named '{s}'. Try `metalbrew update`.\n", .{only.?});
                    return;
                },
                else => return e,
            };
            if (plans.len == 0) {
                try w.writeAll("Everything up to date.\n");
                return;
            }

            const http = try HttpClient.init(init.gpa);
            defer http.deinit();
            var fetcher = GhcrFetcher{ .http = http };
            const tag = os_tag.detectArm64Tag(io, a) catch |e| switch (e) {
                error.UnsupportedMacOS => {
                    try w.writeAll("Unsupported macOS version (no arm64 bottle tag).\n");
                    return;
                },
                else => return e,
            };
            const tags = [_][]const u8{tag.text};

            const uninstaller = uninstall_app.Uninstaller{
                .io = io,
                .allocator = a,
                .receipts = receipts.port(),
                .prefix_abs = paths.prefix,
                .cellar_dir = cellar_dir,
            };
            const installer = install_app.Installer{
                .io = io,
                .allocator = a,
                .catalog = cat.port(),
                .fetcher = fetcher.port(),
                .receipts = receipts.port(),
                .cellar_dir = cellar_dir,
                .cellar_abs = cellar_abs,
                .prefix_abs = paths.prefix,
                .tags = &tags,
            };

            for (plans) |p| {
                try uninstaller.uninstall(p.name);
                _ = try installer.install(p.name);
                try w.print("Upgraded {s} {s} -> {s}\n", .{ p.name, p.old_version, p.new_version });
            }
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
        \\metalbrew — a Homebrew reimplementation
        \\
        \\Usage:
        \\  metalbrew update             Refresh the formula index
        \\  metalbrew info <formula>     Show formula metadata
        \\  metalbrew search <query>     Search formula names
        \\  metalbrew deps <formula>     Show transitive runtime dependencies
        \\  metalbrew install <formula>  Install a formula and its dependencies
        \\  metalbrew list               List installed packages
        \\  metalbrew uninstall <formula> Remove an installed formula
        \\  metalbrew upgrade [<formula>] Upgrade installed packages (all, or one)
        \\
    );
}
