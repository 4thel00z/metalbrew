const std = @import("std");
const progress = @import("progress.zig");

/// Owns an Io + std.http.Client for the process lifetime. Heap-allocated; construct once in main.
pub const HttpClient = struct {
    threaded: std.Io.Threaded,
    client: std.http.Client,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*HttpClient {
        // Heap-allocate so that `self.threaded.io()` is taken when `self` is
        // already at its final, stable address. `Io.userdata` points at the
        // `Threaded` value's address; returning the struct by value would copy
        // `Threaded` to a new address and leave `client.io.userdata` dangling.
        const self = try allocator.create(HttpClient);
        self.allocator = allocator;
        self.threaded = .init(allocator, .{});
        self.client = .{ .allocator = allocator, .io = self.threaded.io() };
        return self;
    }

    pub fn deinit(self: *HttpClient) void {
        self.client.deinit();
        self.threaded.deinit();
        self.allocator.destroy(self);
    }

    /// GET `url`, returning the response body as a slice owned by `allocator`.
    /// Errors with error.HttpStatus on any non-200 response.
    pub fn getAlloc(self: *HttpClient, allocator: std.mem.Allocator, url: []const u8) ![]u8 {
        return self.getAllocHeaders(allocator, url, &.{});
    }

    /// GET `url` with `headers` attached as extra request headers, returning the
    /// response body as a slice owned by `allocator`. Errors with
    /// error.HttpStatus on any non-200 response.
    pub fn getAllocHeaders(self: *HttpClient, allocator: std.mem.Allocator, url: []const u8, headers: []const std.http.Header) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        const res = try self.client.fetch(.{
            .location = .{ .url = url },
            .extra_headers = headers,
            .response_writer = &aw.writer,
        });
        if (@intFromEnum(res.status) != 200) {
            aw.deinit();
            return error.HttpStatus;
        }
        return aw.toOwnedSlice();
    }

    /// GET `url` with `headers`, streaming the (possibly compressed) body and
    /// reporting progress on `bar`. Returns the decompressed body owned by
    /// `allocator`. A percentage is shown only for identity-encoded responses;
    /// for gzip/zstd a downloaded-MB counter is shown (since `content_length`
    /// is the compressed size). Errors with error.HttpStatus on non-200.
    pub fn getAllocProgress(
        self: *HttpClient,
        allocator: std.mem.Allocator,
        url: []const u8,
        headers: []const std.http.Header,
        bar: ?*progress.Bar,
    ) ![]u8 {
        const uri = try std.Uri.parse(url);
        var req = try self.client.request(.GET, uri, .{
            .keep_alive = false,
            .redirect_behavior = @enumFromInt(3),
            .extra_headers = headers,
        });
        defer req.deinit();
        try req.sendBodiless();
        var redirect_buf: [8 * 1024]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);
        if (@intFromEnum(response.head.status) != 200) return error.HttpStatus;
        const enc = response.head.content_encoding;
        const total: ?u64 = if (enc == .identity) response.head.content_length else null;
        var transfer_buf: [4096]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const dbuf = switch (enc) {
            .identity => try allocator.alloc(u8, 0),
            .zstd => try allocator.alloc(u8, std.compress.zstd.default_window_len),
            .deflate, .gzip => try allocator.alloc(u8, std.compress.flate.max_window_len),
            .compress => return error.UnsupportedCompression,
        };
        defer allocator.free(dbuf);
        const reader = response.readerDecompressing(&transfer_buf, &decompress, dbuf);
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(allocator);
        var chunk: [64 * 1024]u8 = undefined;
        var downloaded: u64 = 0;
        if (bar) |b| b.start();
        while (true) {
            const n = reader.readSliceShort(&chunk) catch |e| return e; // ShortError; 0 = EOF
            if (n == 0) break;
            try list.appendSlice(allocator, chunk[0..n]);
            downloaded += n;
            if (bar) |b| b.update(downloaded, total);
        }
        if (bar) |b| b.finish(true);
        return list.toOwnedSlice(allocator);
    }
};

/// Returns true if the environment variable `name` is set in the current
/// process. Built directly from `std.c.environ` so it works from any function
/// without threading the startup environ block through.
fn envIsSet(comptime name: []const u8) bool {
    const environ: std.process.Environ = .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
    return environ.containsConstant(name);
}

test "getAlloc fetches the brew API (network)" {
    if (envIsSet("METALBREW_SKIP_NET")) return error.SkipZigTest;
    const a = std.testing.allocator;
    const http = try HttpClient.init(a);
    defer http.deinit();
    const body = http.getAlloc(a, "https://formulae.brew.sh/api/formula/wget.json") catch |e| {
        std.debug.print("network test skipped: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    defer a.free(body);
    try std.testing.expect(body.len > 100);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\"") != null);
}

test "getAllocHeaders fetches a ghcr bottle blob with auth (network)" {
    if (envIsSet("METALBREW_SKIP_NET")) return error.SkipZigTest;
    const a = std.testing.allocator;
    const http = try HttpClient.init(a);
    defer http.deinit();
    const url = "https://ghcr.io/v2/homebrew/core/xz/blobs/sha256:55c891f5d47142fe923c87df0e3343d7ef2bc7d368c67892b4ad2c80e53069d5";
    const body = http.getAllocHeaders(a, url, &.{
        .{ .name = "authorization", .value = "Bearer QQ==" },
    }) catch |e| {
        std.debug.print("network test skipped: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    defer a.free(body);
    try std.testing.expect(body.len > 1000);
    try std.testing.expect(body[0] == 0x1f and body[1] == 0x8b);
}

test "getAllocProgress streams the brew index (network)" {
    if (envIsSet("METALBREW_SKIP_NET")) return error.SkipZigTest;
    const a = std.testing.allocator;
    const http = try HttpClient.init(a);
    defer http.deinit();
    const body = http.getAllocProgress(a, "https://formulae.brew.sh/api/formula.json", &.{}, null) catch |e| {
        std.debug.print("network test skipped: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    defer a.free(body);
    try std.testing.expect(body.len > 1_000_000);
    try std.testing.expect(body[0] == '[');
}
