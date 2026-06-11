//! Adapter: detect the host macOS version and map it to an arm64 bottle Tag.
//! This is the first place metalbrew spawns a subprocess on Zig 0.16.
//!
//! Subprocess capture API (Zig 0.16.0):
//!   const res = try std.process.run(allocator, io, .{ .argv = &.{ "sw_vers", "-productVersion" } });
//!   defer allocator.free(res.stdout);
//!   defer allocator.free(res.stderr);
//!   // res.term: std.process.Child.Term (.exited = u8, .signal, .stopped, .unknown)
//!   // res.stdout / res.stderr: []u8 owned by the caller.
//! This is the high-level wrapper; it spawns with stdout/stderr = .pipe, waits,
//! and returns owned stdout/stderr slices.
const std = @import("std");
const platform = @import("../domain/platform.zig");

/// Detect host macOS major version → arm64 bottle Tag. Errors UnsupportedMacOS for unknown versions.
pub fn detectArm64Tag(io: std.Io, allocator: std.mem.Allocator) !platform.Tag {
    const major = try macosMajor(io, allocator);
    return platform.arm64TagForMacOS(major) orelse error.UnsupportedMacOS;
}

/// Detect host macOS major → ordered arm64 bottle-tag fallback list (current OS first,
/// then older releases). Lets install fall back to an older-OS bottle when the current
/// release hasn't been bottled yet (mirrors Homebrew). The returned slice is backed by
/// static string literals — no allocation, valid for the program lifetime. Errors
/// UnsupportedMacOS when the version maps to no known tags.
pub fn detectArm64FallbackTags(io: std.Io, allocator: std.mem.Allocator) ![]const []const u8 {
    const major = try macosMajor(io, allocator);
    const tags = platform.arm64FallbackTags(major);
    if (tags.len == 0) return error.UnsupportedMacOS;
    return tags;
}

/// Run `sw_vers -productVersion` and parse the leading major version (e.g. "26.4" -> 26).
fn macosMajor(io: std.Io, allocator: std.mem.Allocator) !u32 {
    const res = try std.process.run(allocator, io, .{
        .argv = &.{ "sw_vers", "-productVersion" },
    });
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);

    switch (res.term) {
        .exited => |code| if (code != 0) return error.SwVersFailed,
        else => return error.SwVersFailed,
    }

    return parseMajor(res.stdout);
}

/// Parse the leading major version out of a `sw_vers -productVersion` string.
/// Takes characters up to the first '.' and parses them as a u32.
/// Trailing whitespace/newlines are trimmed. e.g. "26.4\n" -> 26, "15" -> 15.
fn parseMajor(version: []const u8) !u32 {
    const trimmed = std.mem.trim(u8, version, " \t\r\n");
    const end = std.mem.indexOfScalar(u8, trimmed, '.') orelse trimmed.len;
    return std.fmt.parseInt(u32, trimmed[0..end], 10);
}

test "parseMajor extracts integer before the dot" {
    try std.testing.expectEqual(@as(u32, 26), try parseMajor("26.4"));
    try std.testing.expectEqual(@as(u32, 15), try parseMajor("15.1.2"));
    try std.testing.expectEqual(@as(u32, 14), try parseMajor("14"));
    try std.testing.expectEqual(@as(u32, 26), try parseMajor("26.4\n"));
    try std.testing.expectError(error.InvalidCharacter, parseMajor("vNope"));
}

test "detectArm64Tag on host returns an arm64_ tag" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const tag = detectArm64Tag(io, std.testing.allocator) catch |e| {
        std.debug.print("detect skipped: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    try std.testing.expect(std.mem.startsWith(u8, tag.text, "arm64_"));
}

test "detectArm64FallbackTags on host returns current tag first" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const tags = detectArm64FallbackTags(io, std.testing.allocator) catch |e| {
        std.debug.print("detect skipped: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    try std.testing.expect(tags.len >= 1);
    try std.testing.expect(std.mem.startsWith(u8, tags[0], "arm64_"));
}
