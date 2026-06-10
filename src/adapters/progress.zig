const std = @import("std");

/// A colorful, in-place download progress bar. Renders to `w` only when `enabled`
/// (callers pass enabled = stderr-is-a-tty). Percentage when `total` is known,
/// else a downloaded-bytes counter.
pub const Bar = struct {
    w: *std.Io.Writer,
    enabled: bool,
    label: []const u8 = "",
    width: usize = 22,

    pub fn init(w: *std.Io.Writer, enabled: bool) Bar {
        return .{ .w = w, .enabled = enabled };
    }

    pub fn setLabel(self: *Bar, label: []const u8) void {
        self.label = label;
    }

    pub fn start(self: *Bar) void {
        _ = self;
    }

    /// Render one frame in place (leading carriage return, no newline).
    pub fn update(self: *Bar, downloaded: u64, total: ?u64) void {
        if (!self.enabled) return;
        self.render(downloaded, total, false) catch {};
    }

    /// Final frame (green, 100%/done) + newline.
    pub fn finish(self: *Bar, ok: bool) void {
        if (!self.enabled) return;
        self.render(0, null, ok) catch {};
        self.w.writeAll("\n") catch {};
        self.w.flush() catch {};
    }

    fn render(self: *Bar, downloaded: u64, total: ?u64, done: bool) !void {
        const ORANGE = "\x1b[38;5;208m";
        const GREY = "\x1b[38;5;236m";
        const GREEN = "\x1b[32m";
        const RESET = "\x1b[0m";
        try self.w.writeAll("\r  ");
        try self.w.print("{s}", .{self.label});
        try self.w.writeAll("  \u{2595}"); // left edge ▕
        if (done) {
            // full green bar
            try self.w.writeAll(GREEN);
            var i: usize = 0;
            while (i < self.width) : (i += 1) try self.w.writeAll("\u{2588}");
            try self.w.writeAll(RESET ++ "\u{258f}"); // right edge ▏
            try self.w.writeAll(" 100%  done    ");
            return;
        }
        if (total) |t| {
            const frac: f64 = if (t == 0) 0 else @as(f64, @floatFromInt(downloaded)) / @as(f64, @floatFromInt(t));
            const filled: usize = @intFromFloat(frac * @as(f64, @floatFromInt(self.width)));
            try self.w.writeAll(ORANGE);
            var i: usize = 0;
            while (i < filled) : (i += 1) try self.w.writeAll("\u{2588}");
            try self.w.writeAll(GREY);
            while (i < self.width) : (i += 1) try self.w.writeAll("\u{2591}");
            try self.w.writeAll(RESET ++ "\u{258f}");
            try self.w.print(" {d:>3.0}%  {d:.1}/{d:.1} MB ", .{
                frac * 100.0,
                mb(downloaded),
                mb(t),
            });
        } else {
            // unknown total: orange bar fills + show MB
            try self.w.writeAll(ORANGE);
            var i: usize = 0;
            while (i < self.width) : (i += 1) try self.w.writeAll("\u{2588}");
            try self.w.writeAll(RESET ++ "\u{258f}");
            try self.w.print("  {d:.1} MB ", .{mb(downloaded)});
        }
    }

    fn mb(b: u64) f64 {
        return @as(f64, @floatFromInt(b)) / 1_000_000.0;
    }
};

test "bar renders percentage when total known, into an injected writer" {
    const a = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    var bar = Bar.init(&aw.writer, true);
    bar.setLabel("openssl@3");
    bar.update(1_700_000, 3_400_000); // 50%
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "openssl@3") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "50%") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[38;5;208m") != null); // orange present
}

test "bar disabled writes nothing" {
    const a = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    var bar = Bar.init(&aw.writer, false);
    bar.update(1, 2);
    bar.finish(true);
    try std.testing.expectEqual(@as(usize, 0), aw.written().len);
}

test "bar shows MB without percentage when total unknown" {
    const a = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    var bar = Bar.init(&aw.writer, true);
    bar.setLabel("index");
    bar.update(12_400_000, null);
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "12.4 MB") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "%") == null);
}
