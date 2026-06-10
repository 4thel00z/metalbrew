const std = @import("std");
const Version = @import("version.zig").Version;

/// A declared dependency on another formula. M1 only models the name and whether
/// it is a build-only dependency (which we exclude from runtime resolution).
pub const Dependency = struct {
    name: []const u8,
    build_only: bool = false,
};

/// Where a prebuilt bottle for one platform tag lives, plus its integrity hash.
pub const BottleSpec = struct {
    tag: []const u8, // e.g. "arm64_tahoe"
    url: []const u8,
    sha256: []const u8,
};

/// The domain aggregate: everything metalbrew knows about one package.
pub const Formula = struct {
    name: []const u8,
    version: Version,
    desc: []const u8 = "",
    homepage: []const u8 = "",
    dependencies: []const Dependency = &.{},
    bottles: []const BottleSpec = &.{},

    /// Find the bottle matching a platform tag, if any.
    pub fn bottleFor(self: Formula, tag: []const u8) ?BottleSpec {
        for (self.bottles) |b| {
            if (std.mem.eql(u8, b.tag, tag)) return b;
        }
        return null;
    }

    /// Runtime dependency names only (build-only deps excluded).
    /// Writes into `out` (must have capacity >= dependencies.len); returns the used slice.
    pub fn runtimeDeps(self: Formula, out: [][]const u8) [][]const u8 {
        var n: usize = 0;
        for (self.dependencies) |d| {
            if (d.build_only) continue;
            out[n] = d.name;
            n += 1;
        }
        return out[0..n];
    }
};

test "bottleFor returns matching tag" {
    const f = Formula{
        .name = "wget",
        .version = Version.init("1.21.4"),
        .bottles = &.{
            .{ .tag = "arm64_sonoma", .url = "u1", .sha256 = "h1" },
            .{ .tag = "arm64_tahoe", .url = "u2", .sha256 = "h2" },
        },
    };
    const b = f.bottleFor("arm64_tahoe").?;
    try std.testing.expectEqualStrings("u2", b.url);
    try std.testing.expect(f.bottleFor("x86_64_linux") == null);
}

test "runtimeDeps excludes build-only" {
    const f = Formula{
        .name = "wget",
        .version = Version.init("1.21.4"),
        .dependencies = &.{
            .{ .name = "pkg-config", .build_only = true },
            .{ .name = "libidn2" },
            .{ .name = "openssl@3" },
        },
    };
    var buf: [8][]const u8 = undefined;
    const rt = f.runtimeDeps(&buf);
    try std.testing.expectEqual(@as(usize, 2), rt.len);
    try std.testing.expectEqualStrings("libidn2", rt[0]);
    try std.testing.expectEqualStrings("openssl@3", rt[1]);
}
