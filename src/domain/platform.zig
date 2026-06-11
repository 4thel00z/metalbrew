const std = @import("std");

/// A bottle platform tag, e.g. "arm64_tahoe". Pure value object.
pub const Tag = struct {
    text: []const u8,
    pub fn eql(a: Tag, b: Tag) bool {
        return std.mem.eql(u8, a.text, b.text);
    }
};

/// Map a macOS major version to its arm64 bottle codename tag.
pub fn arm64TagForMacOS(major: u32) ?Tag {
    const name: []const u8 = switch (major) {
        26 => "arm64_tahoe",
        15 => "arm64_sequoia",
        14 => "arm64_sonoma",
        13 => "arm64_ventura",
        12 => "arm64_monterey",
        else => return null,
    };
    return .{ .text = name };
}

/// Ordered fallback list (current first) so install can pick the best available bottle.
/// `all` is appended last: Homebrew tags arch-independent formulae (certs, pure scripts,
/// data-only packages — ~a third of the index) with a single `all` bottle and no
/// `arm64_*` variant, so it must be accepted as a last resort or those formulae (and any
/// package depending on them, e.g. openssl@3 -> ca-certificates) fail with NoBottleForPlatform.
pub fn arm64FallbackTags(major: u32) []const []const u8 {
    return switch (major) {
        26 => &.{ "arm64_tahoe", "arm64_sequoia", "arm64_sonoma", "all" },
        15 => &.{ "arm64_sequoia", "arm64_sonoma", "arm64_ventura", "all" },
        14 => &.{ "arm64_sonoma", "arm64_ventura", "arm64_monterey", "all" },
        else => &.{},
    };
}

test "arm64 tag mapping" {
    try std.testing.expectEqualStrings("arm64_tahoe", arm64TagForMacOS(26).?.text);
    try std.testing.expectEqualStrings("arm64_sequoia", arm64TagForMacOS(15).?.text);
    try std.testing.expect(arm64TagForMacOS(99) == null);
}
test "fallback list current-first" {
    const fb = arm64FallbackTags(26);
    try std.testing.expectEqualStrings("arm64_tahoe", fb[0]);
    try std.testing.expect(fb.len >= 1);
}

test "fallback list ends with the arch-independent `all` tag" {
    // `all` must be the last resort so arch-independent bottles (ca-certificates etc.)
    // and their dependents resolve instead of failing with NoBottleForPlatform.
    inline for (.{ 26, 15, 14 }) |major| {
        const fb = arm64FallbackTags(major);
        try std.testing.expectEqualStrings("all", fb[fb.len - 1]);
    }
}
