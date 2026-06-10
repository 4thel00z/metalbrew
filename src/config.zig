const std = @import("std");

/// Resolved filesystem layout for a metalbrew installation.
pub const Paths = struct {
    prefix: []const u8, // ~/.metalbrew (or the override)
    cache_api: []const u8, // <prefix>/cache/api

    /// Resolve paths. `prefix_override` (from $METALBREW_PREFIX) wins; otherwise
    /// the default is `<home>/.metalbrew`. All returned strings owned by `allocator`.
    pub fn resolve(allocator: std.mem.Allocator, home: []const u8, prefix_override: ?[]const u8) !Paths {
        const prefix = if (prefix_override) |p|
            try allocator.dupe(u8, p)
        else
            try std.fs.path.join(allocator, &.{ home, ".metalbrew" });
        errdefer allocator.free(prefix);
        const cache_api = try std.fs.path.join(allocator, &.{ prefix, "cache", "api" });
        return .{ .prefix = prefix, .cache_api = cache_api };
    }

    pub fn deinit(self: Paths, allocator: std.mem.Allocator) void {
        allocator.free(self.prefix);
        allocator.free(self.cache_api);
    }
};

test "resolve defaults to <home>/.metalbrew" {
    const a = std.testing.allocator;
    const paths = try Paths.resolve(a, "/Users/test", null);
    defer paths.deinit(a);
    try std.testing.expectEqualStrings("/Users/test/.metalbrew", paths.prefix);
    try std.testing.expectEqualStrings("/Users/test/.metalbrew/cache/api", paths.cache_api);
}

test "resolve honors prefix override" {
    const a = std.testing.allocator;
    const paths = try Paths.resolve(a, "/Users/test", "/opt/mb");
    defer paths.deinit(a);
    try std.testing.expectEqualStrings("/opt/mb", paths.prefix);
    try std.testing.expectEqualStrings("/opt/mb/cache/api", paths.cache_api);
}
