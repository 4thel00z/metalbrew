const std = @import("std");

/// Global options that may precede the subcommand verb.
pub const Globals = struct {
    /// Override for the formula API base URL (`--api-url`). null = unset.
    api_url: ?[]const u8 = null,
};

/// Result of stripping global options off the front of argv.
pub const ParsedArgs = struct {
    globals: Globals,
    /// Remaining args (verb + its operands), to feed to `Command.parse`.
    rest: []const []const u8,
};

/// Consume recognised global options from the front of `args`, returning the
/// parsed globals and the remaining args. Scanning stops at the first token
/// that isn't a recognised global (i.e. the verb), so options like
/// `install --foo` after the verb are left untouched. Supports both
/// `--api-url=<url>` and `--api-url <url>` forms. No allocation: results alias
/// `args`.
pub fn parseGlobals(args: []const []const u8) ParsedArgs {
    var globals = Globals{};
    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.startsWith(u8, arg, "--api-url=")) {
            globals.api_url = arg["--api-url=".len..];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--api-url")) {
            if (i + 1 >= args.len) break; // missing value: treat as end
            globals.api_url = args[i + 1];
            i += 2;
        } else break; // first non-global token: the verb
    }
    return .{ .globals = globals, .rest = args[i..] };
}

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
    skill_install,
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
        if (std.mem.eql(u8, cmd, "skill")) return if (args.len >= 2 and std.mem.eql(u8, args[1], "install")) .skill_install else .help;
        return .{ .unknown = cmd };
    }
};

test "parseGlobals: no globals leaves args intact" {
    const args = [_][]const u8{ "install", "wget" };
    const p = parseGlobals(&args);
    try std.testing.expect(p.globals.api_url == null);
    try std.testing.expectEqual(@as(usize, 2), p.rest.len);
    try std.testing.expectEqualStrings("install", p.rest[0]);
    try std.testing.expectEqualStrings("wget", p.rest[1]);
}

test "parseGlobals: --api-url=URL form, rest is verb + operands" {
    const args = [_][]const u8{ "--api-url=https://m.example/api", "install", "wget" };
    const p = parseGlobals(&args);
    try std.testing.expectEqualStrings("https://m.example/api", p.globals.api_url.?);
    try std.testing.expectEqual(@as(usize, 2), p.rest.len);
    try std.testing.expectEqualStrings("install", p.rest[0]);
    try std.testing.expectEqualStrings("wget", p.rest[1]);
}

test "parseGlobals: --api-url URL space form" {
    const args = [_][]const u8{ "--api-url", "https://m.example/api", "search", "ssl" };
    const p = parseGlobals(&args);
    try std.testing.expectEqualStrings("https://m.example/api", p.globals.api_url.?);
    try std.testing.expectEqual(@as(usize, 2), p.rest.len);
    try std.testing.expectEqualStrings("search", p.rest[0]);
    try std.testing.expectEqualStrings("ssl", p.rest[1]);
}

test "parseGlobals: stops at the verb, leaving later flags untouched" {
    const args = [_][]const u8{ "install", "--api-url=https://m.example/api" };
    const p = parseGlobals(&args);
    try std.testing.expect(p.globals.api_url == null);
    try std.testing.expectEqual(@as(usize, 2), p.rest.len);
    try std.testing.expectEqualStrings("install", p.rest[0]);
    try std.testing.expectEqualStrings("--api-url=https://m.example/api", p.rest[1]);
}

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
    try std.testing.expect(Command.parse(&.{ "skill", "install" }) == .skill_install);
    try std.testing.expect(Command.parse(&.{"skill"}) == .help);
    try std.testing.expect(Command.parse(&.{ "skill", "frobnicate" }) == .help);
    try std.testing.expect(Command.parse(&.{"install"}) == .help);
    try std.testing.expect(Command.parse(&.{"uninstall"}) == .help);
    try std.testing.expectEqualStrings("frobnicate", Command.parse(&.{"frobnicate"}).unknown);
    try std.testing.expect(Command.parse(&.{"info"}) == .help);
}
