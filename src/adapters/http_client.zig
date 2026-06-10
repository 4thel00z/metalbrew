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
        var aw: std.Io.Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        const res = try self.client.fetch(.{
            .location = .{ .url = url },
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
