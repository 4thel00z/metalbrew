const std = @import("std");
const Formula = @import("../domain/formula.zig").Formula;
const PackageCatalog = @import("../ports/catalog.zig").PackageCatalog;
const json_api = @import("json_api_catalog.zig");

pub const CachedIndexCatalog = struct {
    arena: std.heap.ArenaAllocator,
    by_name: std.StringHashMapUnmanaged(Formula) = .empty,

    /// Build from the raw full-index bytes (a JSON ARRAY of formula objects).
    pub fn init(backing: std.mem.Allocator, index_bytes: []const u8) !CachedIndexCatalog {
        var self = CachedIndexCatalog{ .arena = std.heap.ArenaAllocator.init(backing) };
        const a = self.arena.allocator();
        const parsed = try std.json.parseFromSlice(std.json.Value, a, index_bytes, .{});
        // parsed lives in the arena; do not deinit separately
        for (parsed.value.array.items) |item| {
            const f = try json_api.formulaFromValue(a, item);
            try self.by_name.put(a, f.name, f);
        }
        return self;
    }
    pub fn deinit(self: *CachedIndexCatalog) void {
        self.arena.deinit();
    }

    pub fn port(self: *CachedIndexCatalog) PackageCatalog {
        return .{ .ptr = self, .vtable = &vtable };
    }
    const vtable = PackageCatalog.VTable{ .get = getImpl, .names = namesImpl };

    fn getImpl(ptr: *anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!?Formula {
        _ = allocator;
        const self: *CachedIndexCatalog = @ptrCast(@alignCast(ptr));
        return self.by_name.get(name);
    }
    fn namesImpl(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![][]const u8 {
        const self: *CachedIndexCatalog = @ptrCast(@alignCast(ptr));
        var list: std.ArrayList([]const u8) = .empty;
        var it = self.by_name.keyIterator();
        while (it.next()) |k| try list.append(allocator, k.*);
        return list.toOwnedSlice(allocator);
    }

    test "CachedIndexCatalog parses a small index array" {
        const a = std.testing.allocator;
        const bytes =
            \\[{"name":"a","versions":{"stable":"1.0"},"dependencies":["b"]},
            \\ {"name":"b","versions":{"stable":"2.0"}}]
        ;
        var cat = try CachedIndexCatalog.init(a, bytes);
        defer cat.deinit();
        const p = cat.port();
        const fa = (try p.get(a, "a")).?;
        try std.testing.expectEqualStrings("a", fa.name);
        try std.testing.expectEqual(@as(usize, 1), fa.dependencies.len);
        try std.testing.expect((try p.get(a, "ghost")) == null);
        const ns = try p.names(a);
        defer a.free(ns);
        try std.testing.expectEqual(@as(usize, 2), ns.len);
    }
};
