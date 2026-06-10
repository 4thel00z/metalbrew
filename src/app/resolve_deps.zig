const std = @import("std");
const PackageCatalog = @import("../ports/catalog.zig").PackageCatalog;
const resolver = @import("../domain/resolver.zig");
const Formula = @import("../domain/formula.zig").Formula;

/// Transitive runtime dependency order for `name`. Loads needed formulae via the catalog.
pub fn run(allocator: std.mem.Allocator, catalog: PackageCatalog, name: []const u8) ![][]const u8 {
    var ctx = Ctx{ .catalog = catalog, .allocator = allocator, .cache = .empty };
    defer ctx.cache.deinit(allocator);
    return resolver.resolve(allocator, &ctx, Ctx.lookup, name);
}

const Ctx = struct {
    catalog: PackageCatalog,
    allocator: std.mem.Allocator,
    cache: std.StringHashMapUnmanaged(Formula),

    fn lookup(ptr: *const anyopaque, name: []const u8) ?Formula {
        const self: *Ctx = @constCast(@ptrCast(@alignCast(ptr)));
        if (self.cache.get(name)) |f| return f;
        const f = (self.catalog.get(self.allocator, name) catch return null) orelse return null;
        self.cache.put(self.allocator, name, f) catch return null;
        return f;
    }
};

const FakeCatalog = @import("../ports/catalog.zig").FakeCatalog;
const Version = @import("../domain/version.zig").Version;

test "ResolveDeps walks the catalog graph" {
    const a = std.testing.allocator;
    var fake = FakeCatalog{};
    defer fake.map.deinit(a);
    try fake.map.put(a, "a", .{ .name = "a", .version = Version.init("1"), .dependencies = &.{.{ .name = "b" }} });
    try fake.map.put(a, "b", .{ .name = "b", .version = Version.init("1") });
    const order = try run(a, fake.port(), "a");
    defer a.free(order);
    try std.testing.expectEqual(@as(usize, 2), order.len);
    try std.testing.expectEqualStrings("b", order[0]);
    try std.testing.expectEqualStrings("a", order[1]);
}
