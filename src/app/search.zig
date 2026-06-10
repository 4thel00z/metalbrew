const std = @import("std");
const PackageCatalog = @import("../ports/catalog.zig").PackageCatalog;

/// Names containing `query` (case-insensitive substring), sorted ascending. Caller owns slice.
pub fn run(allocator: std.mem.Allocator, catalog: PackageCatalog, query: []const u8) ![][]const u8 {
    const all = try catalog.names(allocator);
    defer allocator.free(all);
    var hits: std.ArrayList([]const u8) = .empty;
    for (all) |name| if (containsIgnoreCase(name, query)) try hits.append(allocator, name);
    const out = try hits.toOwnedSlice(allocator);
    std.mem.sort([]const u8, out, {}, lessThan);
    return out;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

const FakeCatalog = @import("../ports/catalog.zig").FakeCatalog;
const Version = @import("../domain/version.zig").Version;

test "Search returns sorted case-insensitive substring matches" {
    const a = std.testing.allocator;
    var fake = FakeCatalog{};
    defer fake.map.deinit(a);
    try fake.map.put(a, "wget", .{ .name = "wget", .version = Version.init("1") });
    try fake.map.put(a, "widget", .{ .name = "widget", .version = Version.init("1") });
    try fake.map.put(a, "curl", .{ .name = "curl", .version = Version.init("1") });
    const hits = try run(a, fake.port(), "GET");
    defer a.free(hits);
    try std.testing.expectEqual(@as(usize, 2), hits.len);
    try std.testing.expectEqualStrings("wget", hits[0]);
    try std.testing.expectEqualStrings("widget", hits[1]);
}
