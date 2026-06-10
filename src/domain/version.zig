const std = @import("std");

/// A package version, e.g. "1.21.4" or "3.0.1_2" (homebrew revision suffix).
pub const Version = struct {
    raw: []const u8,

    pub fn init(raw: []const u8) Version {
        return .{ .raw = raw };
    }

    /// Order by dotted/underscored numeric segments, segment by segment.
    /// Missing segments compare as 0 (so "1.2" < "1.2.1").
    pub fn order(a: Version, b: Version) std.math.Order {
        var it_a = segmentIterator(a.raw);
        var it_b = segmentIterator(b.raw);
        while (true) {
            const sa = it_a.next();
            const sb = it_b.next();
            if (sa == null and sb == null) return .eq;
            const va = sa orelse 0;
            const vb = sb orelse 0;
            if (va < vb) return .lt;
            if (va > vb) return .gt;
        }
    }
};

const SegmentIterator = struct {
    rest: []const u8,
    fn next(self: *SegmentIterator) ?u64 {
        while (self.rest.len > 0 and !std.ascii.isDigit(self.rest[0])) {
            self.rest = self.rest[1..];
        }
        if (self.rest.len == 0) return null;
        var i: usize = 0;
        while (i < self.rest.len and std.ascii.isDigit(self.rest[i])) : (i += 1) {}
        const num = std.fmt.parseInt(u64, self.rest[0..i], 10) catch 0;
        self.rest = self.rest[i..];
        return num;
    }
};

fn segmentIterator(raw: []const u8) SegmentIterator {
    return .{ .rest = raw };
}

test "order: equal versions" {
    try std.testing.expectEqual(std.math.Order.eq, Version.init("1.2.3").order(Version.init("1.2.3")));
}

test "order: patch difference" {
    try std.testing.expectEqual(std.math.Order.lt, Version.init("1.2.3").order(Version.init("1.2.4")));
    try std.testing.expectEqual(std.math.Order.gt, Version.init("1.3.0").order(Version.init("1.2.9")));
}

test "order: differing segment counts" {
    try std.testing.expectEqual(std.math.Order.lt, Version.init("1.2").order(Version.init("1.2.1")));
    try std.testing.expectEqual(std.math.Order.eq, Version.init("1.2.0").order(Version.init("1.2")));
}

test "order: homebrew revision suffix" {
    try std.testing.expectEqual(std.math.Order.lt, Version.init("3.0.1").order(Version.init("3.0.1_2")));
}
