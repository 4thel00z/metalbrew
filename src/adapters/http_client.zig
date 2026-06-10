const std = @import("std");

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
