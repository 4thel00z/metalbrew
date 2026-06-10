const std = @import("std");
const IndexCache = @import("../ports/index_cache.zig").IndexCache;

/// IndexCache backed by a `<dir>/<file_name>` file.
///
/// Holds an `io` and an already-open cache directory handle. The composition
/// root opens/creates the cache directory and constructs this adapter; tests
/// pass a `std.testing.tmpDir` handle. The PORT signature is unchanged.
pub const FsIndexCache = struct {
    io: std.Io,
    dir: std.Io.Dir,
    file_name: []const u8 = "formula.json",

    pub fn port(self: *FsIndexCache) IndexCache {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = IndexCache.VTable{ .read = readImpl, .write = writeImpl };

    fn readImpl(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!?[]u8 {
        const self: *FsIndexCache = @ptrCast(@alignCast(ptr));
        return self.dir.readFileAlloc(self.io, self.file_name, allocator, .unlimited) catch |e| switch (e) {
            error.FileNotFound => return null,
            else => return e,
        };
    }

    fn writeImpl(ptr: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *FsIndexCache = @ptrCast(@alignCast(ptr));
        try self.dir.writeFile(self.io, .{ .sub_path = self.file_name, .data = bytes });
    }
};

test "FsIndexCache write then read round-trips" {
    const a = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cache = FsIndexCache{ .io = io, .dir = tmp.dir };
    const port = cache.port();

    try std.testing.expect((try port.read(a)) == null); // nothing cached yet
    try port.write("[{\"name\":\"wget\"}]");
    const got = (try port.read(a)).?;
    defer a.free(got);
    try std.testing.expectEqualStrings("[{\"name\":\"wget\"}]", got);
}
