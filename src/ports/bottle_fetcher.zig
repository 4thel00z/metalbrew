const std = @import("std");
const progress = @import("../adapters/progress.zig");

/// Driven port: download + verify a bottle tarball's bytes.
pub const BottleFetcher = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Download bottle at `url`, verify sha256 == `sha256_hex` (64 lowercase hex chars),
        /// return the tarball bytes owned by `allocator`. Errors on checksum mismatch / HTTP failure.
        /// `bar` (optional) is updated as the blob streams in.
        fetch: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, url: []const u8, sha256_hex: []const u8, bar: ?*progress.Bar) anyerror![]u8,
    };

    pub fn fetch(self: BottleFetcher, allocator: std.mem.Allocator, url: []const u8, sha256_hex: []const u8, bar: ?*progress.Bar) anyerror![]u8 {
        return self.vtable.fetch(self.ptr, allocator, url, sha256_hex, bar);
    }
};
