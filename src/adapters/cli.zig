const std = @import("std");

pub const Command = union(enum) {
    help,
    update,
    info: []const u8,
    search: []const u8,
    deps: []const u8,
    install: []const u8,
    uninstall: []const u8,
    list,
    upgrade: ?[]const u8,
    unknown: []const u8,

    /// Parse argv[1..] (program name already excluded) into a Command.
    pub fn parse(args: []const []const u8) Command {
        if (args.len == 0) return .help;
        const cmd = args[0];
        if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) return .help;
        if (std.mem.eql(u8, cmd, "update")) return .update;
        if (std.mem.eql(u8, cmd, "info")) return if (args.len >= 2) .{ .info = args[1] } else .help;
        if (std.mem.eql(u8, cmd, "search")) return if (args.len >= 2) .{ .search = args[1] } else .help;
        if (std.mem.eql(u8, cmd, "deps")) return if (args.len >= 2) .{ .deps = args[1] } else .help;
        if (std.mem.eql(u8, cmd, "install")) return if (args.len >= 2) .{ .install = args[1] } else .help;
        if (std.mem.eql(u8, cmd, "uninstall")) return if (args.len >= 2) .{ .uninstall = args[1] } else .help;
        if (std.mem.eql(u8, cmd, "list")) return .list;
        if (std.mem.eql(u8, cmd, "upgrade")) return .{ .upgrade = if (args.len >= 2) args[1] else null };
        return .{ .unknown = cmd };
    }
};

test "parse maps verbs to commands" {
    try std.testing.expect(Command.parse(&.{}) == .help);
    try std.testing.expect(Command.parse(&.{"update"}) == .update);
    try std.testing.expectEqualStrings("wget", Command.parse(&.{ "info", "wget" }).info);
    try std.testing.expectEqualStrings("ssl", Command.parse(&.{ "search", "ssl" }).search);
    try std.testing.expectEqualStrings("wget", Command.parse(&.{ "deps", "wget" }).deps);
    try std.testing.expectEqualStrings("xz", Command.parse(&.{ "install", "xz" }).install);
    try std.testing.expectEqualStrings("xz", Command.parse(&.{ "uninstall", "xz" }).uninstall);
    try std.testing.expect(Command.parse(&.{"list"}) == .list);
    try std.testing.expect(Command.parse(&.{"upgrade"}).upgrade == null);
    try std.testing.expectEqualStrings("xz", Command.parse(&.{ "upgrade", "xz" }).upgrade.?);
    try std.testing.expect(Command.parse(&.{"install"}) == .help);
    try std.testing.expect(Command.parse(&.{"uninstall"}) == .help);
    try std.testing.expectEqualStrings("frobnicate", Command.parse(&.{"frobnicate"}).unknown);
    try std.testing.expect(Command.parse(&.{"info"}) == .help);
}
