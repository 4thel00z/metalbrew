//! Adapter: link an installed keg into the install prefix, Homebrew-style.
//!
//! A poured + relocated keg lives at `<cellar>/<name>/<version>/…` where
//! `<cellar>` is `<prefix>/Cellar`. Homebrew makes the keg's payload visible
//! under the prefix by symlinking each file into `<prefix>/{bin,lib,include,
//! share,sbin,etc,…}`, and by creating the stable handle
//! `<prefix>/opt/<name>` -> the keg root.
//!
//! Design (M2 — simple but correct):
//!   * `link` walks the keg dir. For each regular file (or symlink) at relative
//!     path `<sub>` (e.g. `bin/xz`, `lib/liblzma.5.dylib`,
//!     `lib/pkgconfig/liblzma.pc`), it creates a symlink at `<prefix>/<sub>`
//!     whose target is the ABSOLUTE keg path `<keg_abs>/<sub>`. Absolute targets
//!     are the simplest robust choice. Intermediate dirs under the prefix
//!     (`bin/`, `lib/pkgconfig/`, …) are created as needed.
//!   * An existing symlink at a target path is REPLACED (delete + recreate);
//!     this keeps re-linking idempotent.
//!   * `link` also creates `<prefix>/opt/<name>` -> `<keg_abs>`.
//!
//!   * `unlink` walks the prefix's well-known link dirs plus `opt/`, and for
//!     each SYMLINK whose target starts with `<cellar>/<name>/` (or `opt/<name>`
//!     -> the keg) it deletes the symlink. `<cellar>` = `<prefix>/Cellar`.
//!
//! Zig 0.16 APIs used:
//!   * `std.Io.Dir.symLink(io, target, sub_path, .{})` — create a symlink.
//!   * `std.Io.Dir.readLink(io, sub_path, buf)` — read a symlink's target.
//!   * `std.Io.Dir.createDirPathOpen(io, sub, .{})` — mkdir -p + open.
//!   * `std.Io.Dir.deleteFile(io, sub_path)` — unlink a symlink/file.
//!   * `dir.walk(allocator)` / `walker.next(io)` — recursive walk; the Walker
//!     descends only `.directory` entries, so symlinks surface as `.sym_link`
//!     and are not followed.
const std = @import("std");

/// Subdirectories under the prefix that hold linked artifacts. `opt` is handled
/// separately (it holds the per-keg root link, not file links).
const link_dirs = [_][]const u8{
    "bin", "sbin", "lib", "include", "share", "etc", "libexec", "Frameworks",
};

/// Symlink every file from the keg at `keg_abs` into `prefix_abs`, and create
/// `<prefix_abs>/opt/<name>` -> `<keg_abs>`.
///
/// Existing symlinks at target paths are replaced. `prefix_abs` and `keg_abs`
/// must be absolute paths.
pub fn link(
    io: std.Io,
    allocator: std.mem.Allocator,
    prefix_abs: []const u8,
    keg_abs: []const u8,
    name: []const u8,
) !void {
    var prefix = try std.Io.Dir.openDirAbsolute(io, prefix_abs, .{});
    defer prefix.close(io);

    var keg = try std.Io.Dir.openDirAbsolute(io, keg_abs, .{ .iterate = true });
    defer keg.close(io);

    var walker = try keg.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        // Link regular files and symlinks; skip directories (we mkdir -p them).
        if (entry.kind != .file and entry.kind != .sym_link) continue;

        // Absolute target: <keg_abs>/<sub>.
        const target = try std.fs.path.join(allocator, &.{ keg_abs, entry.path });
        defer allocator.free(target);

        // Ensure the parent dir exists under the prefix (e.g. lib/pkgconfig).
        if (std.fs.path.dirname(entry.path)) |parent| {
            var d = try prefix.createDirPathOpen(io, parent, .{});
            d.close(io);
        }

        try symlinkReplace(io, prefix, target, entry.path);
    }

    // <prefix>/opt/<name> -> <keg_abs>
    var opt = try prefix.createDirPathOpen(io, "opt", .{});
    opt.close(io);
    const opt_sub = try std.fs.path.join(allocator, &.{ "opt", name });
    defer allocator.free(opt_sub);
    try symlinkReplace(io, prefix, keg_abs, opt_sub);
}

/// Create `dir/<sub_path>` -> `target`, replacing any existing entry there.
fn symlinkReplace(io: std.Io, dir: std.Io.Dir, target: []const u8, sub_path: []const u8) !void {
    dir.symLink(io, target, sub_path, .{}) catch |e| switch (e) {
        error.PathAlreadyExists => {
            dir.deleteFile(io, sub_path) catch {};
            try dir.symLink(io, target, sub_path, .{});
        },
        else => return e,
    };
}

/// Remove every symlink under `prefix_abs` whose target points into
/// `<prefix_abs>/Cellar/<name>/`, plus `<prefix_abs>/opt/<name>`.
pub fn unlink(
    io: std.Io,
    allocator: std.mem.Allocator,
    prefix_abs: []const u8,
    name: []const u8,
) !void {
    // The substring a removable link's target must contain: <cellar>/<name>/
    const cellar_prefix = try std.fs.path.join(allocator, &.{ prefix_abs, "Cellar", name });
    defer allocator.free(cellar_prefix);

    var prefix = std.Io.Dir.openDirAbsolute(io, prefix_abs, .{}) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    defer prefix.close(io);

    for (link_dirs) |sub| {
        try unlinkUnder(io, allocator, prefix, sub, cellar_prefix);
    }

    // Drop <prefix>/opt/<name> (a symlink to the keg root). It will not be
    // caught by the walk above because opt/ is not in link_dirs.
    const opt_sub = try std.fs.path.join(allocator, &.{ "opt", name });
    defer allocator.free(opt_sub);
    prefix.deleteFile(io, opt_sub) catch {};
}

/// Walk `<prefix>/<sub>` (if it exists) and delete any symlink whose target
/// starts with `cellar_prefix`.
fn unlinkUnder(
    io: std.Io,
    allocator: std.mem.Allocator,
    prefix: std.Io.Dir,
    sub: []const u8,
    cellar_prefix: []const u8,
) !void {
    var dir = prefix.openDir(io, sub, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound, error.NotDir => return,
        else => return e,
    };
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .sym_link) continue;
        const n = dir.readLink(io, entry.path, &buf) catch continue;
        const target = buf[0..n];
        if (std.mem.startsWith(u8, target, cellar_prefix)) {
            dir.deleteFile(io, entry.path) catch {};
        }
    }
}

// ---------------------------------------------------------------------------
// Tests (offline, tmpDir).
// ---------------------------------------------------------------------------

test "link then unlink a fake keg" {
    const a = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // prefix abs path = the tmp dir itself.
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);

    // Build a fake keg: <root>/Cellar/pkg/1.0/{bin/hello, lib/pkgconfig/p.pc}
    var keg_dir = try tmp.dir.createDirPathOpen(io, "Cellar/pkg/1.0/bin", .{});
    keg_dir.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "Cellar/pkg/1.0/bin/hello", .data = "hello-bin" });
    var pc_dir = try tmp.dir.createDirPathOpen(io, "Cellar/pkg/1.0/lib/pkgconfig", .{});
    pc_dir.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "Cellar/pkg/1.0/lib/pkgconfig/p.pc", .data = "name=pkg" });

    const keg_abs = try std.fs.path.join(a, &.{ root, "Cellar", "pkg", "1.0" });
    defer a.free(keg_abs);

    // --- link ---
    try link(io, a, root, keg_abs, "pkg");

    // <prefix>/bin/hello resolves (through the symlink) to the keg file content.
    {
        const got = try tmp.dir.readFileAlloc(io, "bin/hello", a, .unlimited);
        defer a.free(got);
        try std.testing.expectEqualStrings("hello-bin", got);
    }
    // Nested path linked too.
    {
        const got = try tmp.dir.readFileAlloc(io, "lib/pkgconfig/p.pc", a, .unlimited);
        defer a.free(got);
        try std.testing.expectEqualStrings("name=pkg", got);
    }
    // bin/hello is actually a symlink pointing at the keg file (absolute target).
    {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.readLink(io, "bin/hello", &buf);
        const want = try std.fs.path.join(a, &.{ keg_abs, "bin", "hello" });
        defer a.free(want);
        try std.testing.expectEqualStrings(want, buf[0..n]);
    }
    // <prefix>/opt/pkg exists and resolves to the keg root (read a file through it).
    {
        const got = try tmp.dir.readFileAlloc(io, "opt/pkg/bin/hello", a, .unlimited);
        defer a.free(got);
        try std.testing.expectEqualStrings("hello-bin", got);
    }

    // Re-link is idempotent (replaces existing symlinks).
    try link(io, a, root, keg_abs, "pkg");

    // --- unlink ---
    try unlink(io, a, root, "pkg");

    // bin/hello gone.
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "bin/hello", .{}));
    // nested link gone.
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "lib/pkgconfig/p.pc", .{}));
    // opt/pkg gone.
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "opt/pkg", .{ .follow_symlinks = false }));
    // The keg itself is untouched.
    {
        const got = try tmp.dir.readFileAlloc(io, "Cellar/pkg/1.0/bin/hello", a, .unlimited);
        defer a.free(got);
        try std.testing.expectEqualStrings("hello-bin", got);
    }
}
