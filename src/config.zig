const std = @import("std");

/// Default Homebrew-compatible JSON API base. The index lives at
/// `<base>/formula.json` and a single formula at `<base>/formula/<name>.json`.
pub const DEFAULT_API_BASE = "https://formulae.brew.sh/api";

/// Where formula metadata is fetched from. A single base URL; both the index
/// and per-formula endpoints derive from it, so pointing this at a mirror
/// redirects everything.
pub const Source = struct {
    api_base: []const u8,

    /// Resolve the API base with precedence flag > env > built-in default.
    /// Any trailing slashes are trimmed so URL joins stay clean. The returned
    /// base aliases whichever input was chosen (or the default constant) — no
    /// allocation; the caller keeps the inputs alive.
    pub fn resolve(flag_override: ?[]const u8, env_override: ?[]const u8) Source {
        const chosen = flag_override orelse env_override orelse DEFAULT_API_BASE;
        return .{ .api_base = std.mem.trimEnd(u8, chosen, "/") };
    }

    /// URL of the full formula index. Owned by `allocator`.
    pub fn indexUrl(self: Source, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/formula.json", .{self.api_base});
    }

    /// URL of a single formula's metadata. Owned by `allocator`.
    pub fn formulaUrl(self: Source, allocator: std.mem.Allocator, name: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/formula/{s}.json", .{ self.api_base, name });
    }
};

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

test "Source.resolve defaults to the built-in API base" {
    const s = Source.resolve(null, null);
    try std.testing.expectEqualStrings(DEFAULT_API_BASE, s.api_base);
}

test "Source.resolve: env overrides the default" {
    const s = Source.resolve(null, "https://mirror.example/api");
    try std.testing.expectEqualStrings("https://mirror.example/api", s.api_base);
}

test "Source.resolve: flag overrides env and default" {
    const s = Source.resolve("https://flag.example/api", "https://env.example/api");
    try std.testing.expectEqualStrings("https://flag.example/api", s.api_base);
}

test "Source.resolve: trailing slashes are trimmed" {
    const s = Source.resolve(null, "https://mirror.example/api///");
    try std.testing.expectEqualStrings("https://mirror.example/api", s.api_base);
}

test "Source.indexUrl derives <base>/formula.json" {
    const a = std.testing.allocator;
    const s = Source.resolve("https://mirror.example/api", null);
    const url = try s.indexUrl(a);
    defer a.free(url);
    try std.testing.expectEqualStrings("https://mirror.example/api/formula.json", url);
}

test "Source.formulaUrl derives <base>/formula/<name>.json" {
    const a = std.testing.allocator;
    const s = Source.resolve(null, null);
    const url = try s.formulaUrl(a, "wget");
    defer a.free(url);
    try std.testing.expectEqualStrings("https://formulae.brew.sh/api/formula/wget.json", url);
}

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
