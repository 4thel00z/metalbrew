const std = @import("std");
const Formula = @import("formula.zig").Formula;

/// Pure lookup function: name -> Formula (or null if unknown).
pub const Lookup = *const fn (ctx: *const anyopaque, name: []const u8) ?Formula;

pub const ResolveError = error{ UnknownFormula, CycleDetected, OutOfMemory };

/// Transitive runtime dependency closure of `root`, topologically ordered
/// (each formula after all its deps; root last). Caller owns the returned slice.
pub fn resolve(
    allocator: std.mem.Allocator,
    ctx: *const anyopaque,
    lookup: Lookup,
    root: []const u8,
) ResolveError![][]const u8 {
    var order: std.ArrayList([]const u8) = .empty;
    errdefer order.deinit(allocator);
    var visited: std.StringHashMapUnmanaged(State) = .empty;
    defer visited.deinit(allocator);

    try visit(allocator, ctx, lookup, root, &visited, &order);
    return order.toOwnedSlice(allocator);
}

const State = enum { in_progress, done };

fn visit(
    allocator: std.mem.Allocator,
    ctx: *const anyopaque,
    lookup: Lookup,
    name: []const u8,
    visited: *std.StringHashMapUnmanaged(State),
    order: *std.ArrayList([]const u8),
) ResolveError!void {
    if (visited.get(name)) |s| {
        switch (s) {
            .done => return,
            .in_progress => return error.CycleDetected,
        }
    }
    try visited.put(allocator, name, .in_progress);

    const formula = lookup(ctx, name) orelse return error.UnknownFormula;
    var buf: [256][]const u8 = undefined;
    const deps = formula.runtimeDeps(&buf);
    for (deps) |dep| {
        try visit(allocator, ctx, lookup, dep, visited, order);
    }

    try visited.put(allocator, name, .done);
    try order.append(allocator, name);
}

// ---- tests ----
const Version = @import("version.zig").Version;
const Dependency = @import("formula.zig").Dependency;

const TestGraph = struct {
    map: std.StringHashMapUnmanaged(Formula),
    fn lookupFn(ctx: *const anyopaque, name: []const u8) ?Formula {
        const self: *const TestGraph = @ptrCast(@alignCast(ctx));
        return self.map.get(name);
    }
};

fn mkFormula(name: []const u8, deps: []const []const u8, buf: []Dependency) Formula {
    for (deps, 0..) |d, i| buf[i] = Dependency{ .name = d };
    return .{ .name = name, .version = Version.init("1.0"), .dependencies = buf[0..deps.len] };
}

test "resolve: linear chain a->b->c yields c,b,a" {
    const a = std.testing.allocator;
    var g = TestGraph{ .map = .empty };
    defer g.map.deinit(a);
    var db: [1]Dependency = undefined;
    var bb: [1]Dependency = undefined;
    try g.map.put(a, "a", mkFormula("a", &.{"b"}, &db));
    try g.map.put(a, "b", mkFormula("b", &.{"c"}, &bb));
    try g.map.put(a, "c", mkFormula("c", &.{}, &.{}));
    const order = try resolve(a, &g, TestGraph.lookupFn, "a");
    defer a.free(order);
    try std.testing.expectEqual(@as(usize, 3), order.len);
    try std.testing.expectEqualStrings("c", order[0]);
    try std.testing.expectEqualStrings("b", order[1]);
    try std.testing.expectEqualStrings("a", order[2]);
}

test "resolve: diamond dependency deduplicates" {
    const a = std.testing.allocator;
    var g = TestGraph{ .map = .empty };
    defer g.map.deinit(a);
    var top: [2]Dependency = undefined;
    var lb: [1]Dependency = undefined;
    var rb: [1]Dependency = undefined;
    try g.map.put(a, "top", mkFormula("top", &.{ "left", "right" }, &top));
    try g.map.put(a, "left", mkFormula("left", &.{"base"}, &lb));
    try g.map.put(a, "right", mkFormula("right", &.{"base"}, &rb));
    try g.map.put(a, "base", mkFormula("base", &.{}, &.{}));
    const order = try resolve(a, &g, TestGraph.lookupFn, "top");
    defer a.free(order);
    try std.testing.expectEqual(@as(usize, 4), order.len);
    try std.testing.expectEqualStrings("base", order[0]);
    try std.testing.expectEqualStrings("top", order[3]);
}

test "resolve: unknown formula errors" {
    const a = std.testing.allocator;
    var g = TestGraph{ .map = .empty };
    defer g.map.deinit(a);
    try std.testing.expectError(error.UnknownFormula, resolve(a, &g, TestGraph.lookupFn, "ghost"));
}

test "resolve: cycle detected" {
    const a = std.testing.allocator;
    var g = TestGraph{ .map = .empty };
    defer g.map.deinit(a);
    var ab: [1]Dependency = undefined;
    var bb: [1]Dependency = undefined;
    try g.map.put(a, "a", mkFormula("a", &.{"b"}, &ab));
    try g.map.put(a, "b", mkFormula("b", &.{"a"}, &bb));
    try std.testing.expectError(error.CycleDetected, resolve(a, &g, TestGraph.lookupFn, "a"));
}
