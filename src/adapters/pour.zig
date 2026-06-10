//! Pour: decompress a gzip bottle tarball (in memory) and untar it into a
//! destination directory (the Cellar).
//!
//! Homebrew bottle tarballs are already keg-shaped (top-level
//! `<name>/<version>/…`), so pouring into `<prefix>/Cellar` yields
//! `<prefix>/Cellar/<name>/<version>/…`.
//!
//! SECURITY: bottles are untrusted, third-party Homebrew artifacts. The blind
//! `std.tar.extract` rejects `..`/absolute ENTRY NAMES but writes symlink
//! TARGETS (`link_name`) verbatim — so a hostile bottle with a symlink
//! `lib -> /tmp/evil` (or `../../etc`) followed by a file `lib/x` would write
//! OUTSIDE the Cellar (arbitrary write). The sha256 gate does not help against
//! a forged bottle. We therefore iterate entries via `std.tar.Iterator` and
//! enforce our own sanitization (see `isUnsafeName` / `symlinkEscapes`).
const std = @import("std");
const flate = std.compress.flate;

/// Hard cap on cumulative extracted bytes — zip-bomb defense. Real bottles are
/// a few MB; 4 GiB is comically generous while still bounding a hostile bottle.
const MAX_BOTTLE_BYTES: u64 = 4 * 1024 * 1024 * 1024;

/// Buffer for streaming file contents from the tar reader to the fs writer.
const STREAM_BUF_LEN = 64 * 1024;

/// Decompress gzip `bottle_bytes` and untar into `dest_dir`, sanitizing every
/// entry so nothing can be written or pointed outside `dest_dir`.
///
/// Wiring (Zig 0.16):
///   bottle_bytes
///     -> std.Io.Reader.fixed(...)                       fixed reader over the slice
///     -> flate.Decompress.init(&in, .gzip, &window)     gzip container variant
///     -> &decompress.reader                             decompressed output reader
///     -> std.tar.Iterator.init(...)                     iterate entries
///     -> per-entry validate + create (no blind extract)
pub fn pour(io: std.Io, allocator: std.mem.Allocator, dest_dir: std.Io.Dir, bottle_bytes: []const u8) !void {
    _ = allocator; // iterator + streaming use fixed-size stack buffers.

    var in: std.Io.Reader = .fixed(bottle_bytes);

    // Decompress requires a window buffer of at least `flate.max_window_len`
    // for back-references (indirect vtable). Allocate it on the stack.
    var window: [flate.max_window_len]u8 = undefined;
    var decompress: flate.Decompress = .init(&in, .gzip, &window);

    var file_name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var link_name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var it: std.tar.Iterator = .init(&decompress.reader, .{
        .file_name_buffer = &file_name_buf,
        .link_name_buffer = &link_name_buf,
    });

    var stream_buf: [STREAM_BUF_LEN]u8 = undefined;
    var total_bytes: u64 = 0;

    while (try it.next()) |entry| {
        // Rule 1: reject absolute names or any with a ".." component.
        if (isUnsafeName(entry.name)) return error.UnsafeTarEntry;

        switch (entry.kind) {
            .directory => {
                if (entry.name.len > 0) try dest_dir.createDirPath(io, entry.name);
            },
            .file => {
                // Rule (zip-bomb): cap cumulative extracted bytes.
                total_bytes += entry.size;
                if (total_bytes > MAX_BOTTLE_BYTES) return error.BottleTooLarge;

                // mkdir parent within dest_dir only (name already validated safe).
                if (std.fs.path.dirname(entry.name)) |parent| {
                    if (parent.len > 0) try dest_dir.createDirPath(io, parent);
                }
                // Rule 3: exclusive/no-clobber create. Preserve the owner
                // executable bit from the tar header (mirrors std.tar's default
                // `executable_bit_only` mode_mode) so binaries stay runnable.
                const perms: std.Io.File.Permissions = if (std.Io.File.Permissions.has_executable_bit and (entry.mode & 0o100) != 0)
                    .executable_file
                else
                    .default_file;
                var fs_file = try dest_dir.createFile(io, entry.name, .{ .exclusive = true, .permissions = perms });
                defer fs_file.close(io);
                var file_writer = fs_file.writer(io, &stream_buf);
                try it.streamRemaining(entry, &file_writer.interface);
                try file_writer.interface.flush();
            },
            .sym_link => {
                // Rule 2: link target must be relative AND must not escape dest_dir
                // when resolved relative to the symlink's own parent directory.
                if (symlinkEscapes(entry.name, entry.link_name)) return error.UnsafeTarEntry;
                if (std.fs.path.dirname(entry.name)) |parent| {
                    if (parent.len > 0) try dest_dir.createDirPath(io, parent);
                }
                try dest_dir.symLink(io, entry.link_name, entry.name, .{});
            },
        }
    }
}

/// PURE. True if `name` is unsafe to extract: absolute (leading `/`) or
/// contains a `..` path component. Splitting on `/` so `..` only matches a
/// whole component (not e.g. a file literally named `a..b`).
pub fn isUnsafeName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name[0] == '/') return true;
    var it = std.mem.splitScalar(u8, name, '/');
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, "..")) return true;
    }
    return false;
}

/// PURE. True if a symlink at `entry_name` pointing to `link_target` would
/// escape the extraction root. A target escapes if it is absolute, or if —
/// resolved relative to the symlink's OWN parent directory — the normalized
/// path climbs above the root (i.e. its depth goes negative at any point).
///
/// Depth model: start at the directory depth of `entry_name` (number of `/`
/// separators in its parent). Each non-".." / non-"." component descends (+1);
/// each ".." ascends (-1). If depth ever drops below 0, the link escapes the
/// root. Homebrew bottles only ever use relative, in-keg targets, so any
/// escape is malicious.
pub fn symlinkEscapes(entry_name: []const u8, link_target: []const u8) bool {
    if (link_target.len == 0) return false;
    if (link_target[0] == '/') return true; // absolute target

    // Starting depth = number of path components in the symlink's parent dir.
    // e.g. entry "a/b/lnk" -> parent "a/b" -> depth 2.
    var depth: isize = 0;
    if (std.fs.path.dirname(entry_name)) |parent| {
        var pit = std.mem.splitScalar(u8, parent, '/');
        while (pit.next()) |comp| {
            if (comp.len == 0 or std.mem.eql(u8, comp, ".")) continue;
            depth += 1;
        }
    }

    var tit = std.mem.splitScalar(u8, link_target, '/');
    while (tit.next()) |comp| {
        if (comp.len == 0 or std.mem.eql(u8, comp, ".")) continue;
        if (std.mem.eql(u8, comp, "..")) {
            depth -= 1;
            if (depth < 0) return true; // climbed above root
        } else {
            depth += 1;
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// Pure unit tests (no I/O).
// ---------------------------------------------------------------------------

test "isUnsafeName" {
    try std.testing.expect(isUnsafeName("../x"));
    try std.testing.expect(isUnsafeName("/abs"));
    try std.testing.expect(isUnsafeName("a/../../b"));
    try std.testing.expect(isUnsafeName(".."));
    try std.testing.expect(isUnsafeName("a/b/.."));
    try std.testing.expect(!isUnsafeName("a/b"));
    try std.testing.expect(!isUnsafeName("pkg/1.0/bin/hello"));
    try std.testing.expect(!isUnsafeName("a..b/c")); // ".." only as a whole component
    try std.testing.expect(!isUnsafeName(""));
}

test "symlinkEscapes" {
    // absolute target -> escapes
    try std.testing.expect(symlinkEscapes("lib", "/etc"));
    try std.testing.expect(symlinkEscapes("a/b/lib", "/tmp/PWNED"));
    // climbing above root -> escapes
    try std.testing.expect(symlinkEscapes("lib", "../../etc")); // depth 0, ".." -> -1
    try std.testing.expect(symlinkEscapes("a/lib", "../../etc")); // depth 1, "../.." -> -1
    // stays in root -> safe
    try std.testing.expect(!symlinkEscapes("b/symlink", "../a/file")); // depth1 -1+desc = ok
    try std.testing.expect(!symlinkEscapes("bin/foo", "../lib/bar")); // depth1 ->0 ->desc
    try std.testing.expect(!symlinkEscapes("lib", "sibling")); // pure descend
    try std.testing.expect(!symlinkEscapes("a/b/c/lnk", "../../../d")); // depth3 -> 0 -> desc
    // empty target (no symlink target) -> safe
    try std.testing.expect(!symlinkEscapes("lib", ""));
}

test "pour extracts a gzip tarball into dest dir" {
    const a = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const bytes = @embedFile("../testdata/mini-bottle.tar.gz");
    try pour(io, a, tmp.dir, bytes);

    const got = try tmp.dir.readFileAlloc(io, "pkg/1.0/bin/hello", a, .unlimited);
    defer a.free(got);
    try std.testing.expectEqualStrings("hello-bin", got);
}

test "pour rejects a hostile symlink-escape tarball" {
    const a = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Fixture: `lib -> /tmp/PWNED` (absolute-target symlink) + `realdir/x`.
    // pour must refuse with error.UnsafeTarEntry and /tmp/PWNED must NOT exist.
    const bytes = @embedFile("../testdata/evil-symlink.tar.gz");
    try std.testing.expectError(error.UnsafeTarEntry, pour(io, a, tmp.dir, bytes));

    // Prove nothing escaped: /tmp/PWNED was not created by the extraction.
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(io, "/tmp/PWNED", .{}));
}
