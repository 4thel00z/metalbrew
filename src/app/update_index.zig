const std = @import("std");
const HttpClient = @import("../adapters/http_client.zig").HttpClient;
const IndexCache = @import("../ports/index_cache.zig").IndexCache;
const progress = @import("../adapters/progress.zig");
const config = @import("../config.zig");

pub const INDEX_URL = config.DEFAULT_API_BASE ++ "/formula.json";

/// Fetch the full index and store it via the cache port. Returns bytes written.
pub fn run(allocator: std.mem.Allocator, http: *HttpClient, cache: IndexCache, url: []const u8, bar: ?*progress.Bar) !usize {
    const body = try http.getAllocProgress(allocator, url, &.{}, bar);
    defer allocator.free(body);
    try cache.write(body);
    return body.len;
}

const MemCache = struct {
    buf: ?[]u8 = null,
    a: std.mem.Allocator,

    fn port(self: *MemCache) IndexCache {
        return .{ .ptr = self, .vtable = &mem_vtable };
    }
    const mem_vtable = IndexCache.VTable{ .read = rd, .write = wr };

    fn rd(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!?[]u8 {
        const s: *MemCache = @ptrCast(@alignCast(ptr));
        if (s.buf) |b| return try allocator.dupe(u8, b);
        return null;
    }
    fn wr(ptr: *anyopaque, bytes: []const u8) anyerror!void {
        const s: *MemCache = @ptrCast(@alignCast(ptr));
        if (s.buf) |b| s.a.free(b);
        s.buf = try s.a.dupe(u8, bytes);
    }
};

/// Returns true if the environment variable `name` is set in the current process.
/// Mirrors http_client.zig's `envIsSet`.
fn envIsSet(comptime name: []const u8) bool {
    const environ: std.process.Environ = .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
    return environ.containsConstant(name);
}

test "UpdateIndex writes fetched bytes to cache (network)" {
    if (envIsSet("METALBREW_SKIP_NET")) return error.SkipZigTest;
    const a = std.testing.allocator;
    const http = try HttpClient.init(a);
    defer http.deinit();
    var mem = MemCache{ .a = a };
    defer if (mem.buf) |b| a.free(b);
    const n = run(a, http, mem.port(), INDEX_URL, null) catch return error.SkipZigTest;
    try std.testing.expect(n > 1000);
    try std.testing.expect(mem.buf != null);
}
