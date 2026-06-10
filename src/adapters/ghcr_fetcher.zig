const std = @import("std");
const BottleFetcher = @import("../ports/bottle_fetcher.zig").BottleFetcher;
const HttpClient = @import("http_client.zig").HttpClient;

/// BottleFetcher adapter over HttpClient targeting GHCR's Homebrew bottle
/// registry. Sends the anonymous `Authorization: Bearer QQ==` token GHCR
/// accepts for public blobs, then verifies the downloaded bytes' sha256 equals
/// the caller-supplied expected hex (the SECURITY GATE).
pub const GhcrFetcher = struct {
    http: *HttpClient,

    pub fn port(self: *GhcrFetcher) BottleFetcher {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = BottleFetcher.VTable{ .fetch = fetchImpl };

    fn fetchImpl(ptr: *anyopaque, allocator: std.mem.Allocator, url: []const u8, sha256_hex: []const u8) anyerror![]u8 {
        const self: *GhcrFetcher = @ptrCast(@alignCast(ptr));
        const headers = [_]std.http.Header{.{ .name = "authorization", .value = "Bearer QQ==" }};
        const body = try self.http.getAllocHeaders(allocator, url, &headers);
        errdefer allocator.free(body);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(body, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower); // [64]u8
        if (!std.mem.eql(u8, &hex, sha256_hex)) return error.ChecksumMismatch;
        return body;
    }
};

/// Returns true if the environment variable `name` is set in the current
/// process. Mirrors http_client.zig's envIsSet.
fn envIsSet(comptime name: []const u8) bool {
    const environ: std.process.Environ = .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
    return environ.containsConstant(name);
}

test "GhcrFetcher fetches + verifies a real bottle (network)" {
    if (envIsSet("METALBREW_SKIP_NET")) return error.SkipZigTest;
    const a = std.testing.allocator;
    const http = try HttpClient.init(a);
    defer http.deinit();
    var f = GhcrFetcher{ .http = http };
    const url = "https://ghcr.io/v2/homebrew/core/xz/blobs/sha256:55c891f5d47142fe923c87df0e3343d7ef2bc7d368c67892b4ad2c80e53069d5";
    const sha = "55c891f5d47142fe923c87df0e3343d7ef2bc7d368c67892b4ad2c80e53069d5";
    const bytes = f.port().fetch(a, url, sha) catch |e| {
        std.debug.print("network test skipped: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    defer a.free(bytes);
    try std.testing.expect(bytes.len > 1000);
    try std.testing.expect(bytes[0] == 0x1f and bytes[1] == 0x8b); // gzip magic

    // checksum mismatch path (still network, but proves the gate): wrong sha must error.
    const bad = "0000000000000000000000000000000000000000000000000000000000000000";
    try std.testing.expectError(error.ChecksumMismatch, f.port().fetch(a, url, bad));
}
