const std = @import("std");
const Formula = @import("../domain/formula.zig").Formula;

/// Driven port: the application's view of "where formula metadata comes from".
pub const PackageCatalog = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        get: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!?Formula,
        names: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![][]const u8,
    };

    pub fn get(self: PackageCatalog, allocator: std.mem.Allocator, name: []const u8) anyerror!?Formula {
        return self.vtable.get(self.ptr, allocator, name);
    }
    pub fn names(self: PackageCatalog, allocator: std.mem.Allocator) anyerror![][]const u8 {
        return self.vtable.names(self.ptr, allocator);
    }
};

/// In-memory test double, backed by a caller-populated map of name -> Formula.
pub const FakeCatalog = struct {
    map: std.StringHashMapUnmanaged(Formula) = .empty,

    pub fn port(self: *FakeCatalog) PackageCatalog {
        return .{ .ptr = self, .vtable = &vtable };
    }
    const vtable = PackageCatalog.VTable{ .get = getImpl, .names = namesImpl };

    fn getImpl(ptr: *anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!?Formula {
        _ = allocator;
        const self: *FakeCatalog = @ptrCast(@alignCast(ptr));
        return self.map.get(name);
    }
    fn namesImpl(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![][]const u8 {
        const self: *FakeCatalog = @ptrCast(@alignCast(ptr));
        var list: std.ArrayList([]const u8) = .empty;
        var it = self.map.keyIterator();
        while (it.next()) |k| try list.append(allocator, k.*);
        return list.toOwnedSlice(allocator);
    }
};

test "FakeCatalog satisfies the port" {
    const Version = @import("../domain/version.zig").Version;
    const a = std.testing.allocator;
    var fake = FakeCatalog{};
    defer fake.map.deinit(a);
    try fake.map.put(a, "wget", .{ .name = "wget", .version = Version.init("1.21.4") });

    const catalog = fake.port();
    const f = (try catalog.get(a, "wget")).?;
    try std.testing.expectEqualStrings("wget", f.name);
    try std.testing.expect((try catalog.get(a, "ghost")) == null);

    const ns = try catalog.names(a);
    defer a.free(ns);
    try std.testing.expectEqual(@as(usize, 1), ns.len);
}
