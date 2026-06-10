//! Pour: decompress a gzip bottle tarball (in memory) and untar it into a
//! destination directory (the Cellar).
//!
//! Homebrew bottle tarballs are already keg-shaped (top-level
//! `<name>/<version>/…`), so pouring into `<prefix>/Cellar` yields
//! `<prefix>/Cellar/<name>/<version>/…`.
const std = @import("std");
const flate = std.compress.flate;

/// Decompress gzip `bottle_bytes` and untar into `dest_dir`.
///
/// Wiring (Zig 0.16):
///   bottle_bytes
///     -> std.Io.Reader.fixed(...)              fixed reader over the slice
///     -> flate.Decompress.init(&in, .gzip, &window)   gzip container variant
///     -> &decompress.reader                    decompressed output reader
///     -> std.tar.extract(io, dest_dir, ..., .{})       untar into dest_dir
pub fn pour(io: std.Io, allocator: std.mem.Allocator, dest_dir: std.Io.Dir, bottle_bytes: []const u8) !void {
    _ = allocator; // extract uses fixed-size stack buffers internally.

    var in: std.Io.Reader = .fixed(bottle_bytes);

    // Decompress requires a window buffer of at least `flate.max_window_len`
    // for back-references (indirect vtable). Allocate it on the stack.
    var window: [flate.max_window_len]u8 = undefined;
    var decompress: flate.Decompress = .init(&in, .gzip, &window);

    try std.tar.extract(io, dest_dir, &decompress.reader, .{});
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
