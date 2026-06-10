const std = @import("std");
const Formula = @import("../domain/formula.zig").Formula;
const PackageCatalog = @import("../ports/catalog.zig").PackageCatalog;

pub const Error = error{NotFound} || anyerror;

pub fn run(allocator: std.mem.Allocator, catalog: PackageCatalog, name: []const u8) Error!Formula {
    return (try catalog.get(allocator, name)) orelse error.NotFound;
}

const FakeCatalog = @import("../ports/catalog.zig").FakeCatalog;
const Version = @import("../domain/version.zig").Version;

test "GetInfo returns formula or NotFound" {
    const a = std.testing.allocator;
    var fake = FakeCatalog{};
    defer fake.map.deinit(a);
    try fake.map.put(a, "wget", .{ .name = "wget", .version = Version.init("1.21.4"), .desc = "Internet file retriever" });
    const f = try run(a, fake.port(), "wget");
    try std.testing.expectEqualStrings("Internet file retriever", f.desc);
    try std.testing.expectError(error.NotFound, run(a, fake.port(), "ghost"));
}
