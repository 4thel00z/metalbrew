//! App use-case: plan which installed kegs have a newer version in the index.
//! Pure decision over two ports — no install/uninstall side effects here.
const std = @import("std");
const PackageCatalog = @import("../ports/catalog.zig").PackageCatalog;
const ReceiptStore = @import("../ports/receipt_store.zig").ReceiptStore;
const Version = @import("../domain/version.zig").Version;

/// One keg that should be upgraded. All strings owned by the planner's allocator.
pub const Plan = struct {
    name: []const u8,
    old_version: []const u8,
    new_version: []const u8,
};

pub const PlanError = error{ NotInstalled, UnknownFormula } || anyerror;

/// Installed kegs whose index version is newer than the installed one.
/// `only != null` restricts to that keg (error.NotInstalled if no receipt;
/// error.UnknownFormula if the index doesn't list it). `only == null` scans all
/// receipts and silently skips any the index no longer lists. Caller owns the
/// returned slice and every string in it (free via `freePlan` + free the slice).
pub fn plan(
    allocator: std.mem.Allocator,
    catalog: PackageCatalog,
    receipts: ReceiptStore,
    only: ?[]const u8,
) PlanError![]Plan {
    var out: std.ArrayList(Plan) = .empty;
    errdefer {
        for (out.items) |p| freePlan(allocator, p);
        out.deinit(allocator);
    }

    if (only) |name| {
        const r = (try receipts.get(allocator, name)) orelse return error.NotInstalled;
        defer {
            allocator.free(r.name);
            allocator.free(r.version);
        }
        const f = (try catalog.get(allocator, name)) orelse return error.UnknownFormula;
        if (isNewer(r.version, f.version))
            try out.append(allocator, try makePlan(allocator, name, r.version, f.version.raw));
    } else {
        const all = try receipts.list(allocator);
        defer {
            for (all) |r| {
                allocator.free(r.name);
                allocator.free(r.version);
            }
            allocator.free(all);
        }
        for (all) |r| {
            const f = (try catalog.get(allocator, r.name)) orelse continue;
            if (isNewer(r.version, f.version))
                try out.append(allocator, try makePlan(allocator, r.name, r.version, f.version.raw));
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn freePlan(allocator: std.mem.Allocator, p: Plan) void {
    allocator.free(p.name);
    allocator.free(p.old_version);
    allocator.free(p.new_version);
}

fn isNewer(installed_raw: []const u8, current: Version) bool {
    return Version.init(installed_raw).order(current) == .lt;
}

fn makePlan(allocator: std.mem.Allocator, name: []const u8, old: []const u8, new: []const u8) !Plan {
    const n = try allocator.dupe(u8, name);
    errdefer allocator.free(n);
    const o = try allocator.dupe(u8, old);
    errdefer allocator.free(o);
    const nv = try allocator.dupe(u8, new);
    return .{ .name = n, .old_version = o, .new_version = nv };
}

// ---------------------------------------------------------------------------
// Tests (in-memory fakes, leak-checked under std.testing.allocator).
// ---------------------------------------------------------------------------

const FakeCatalog = @import("../ports/catalog.zig").FakeCatalog;
const Receipt = @import("../ports/receipt_store.zig").Receipt;

/// In-memory ReceiptStore fake. Map is populated directly by tests with literal
/// strings; `get`/`list` hand back owned (duped) copies the caller must free.
/// `put`/`remove` are unused no-ops here (this is a read-only planner test).
const FakeReceipts = struct {
    map: std.StringHashMapUnmanaged(Receipt) = .empty,
    gpa: std.mem.Allocator,

    fn deinit(self: *FakeReceipts) void {
        self.map.deinit(self.gpa);
    }
    fn port(self: *FakeReceipts) ReceiptStore {
        return .{ .ptr = self, .vtable = &vtable };
    }
    const vtable = ReceiptStore.VTable{
        .put = putImpl,
        .get = getImpl,
        .list = listImpl,
        .remove = removeImpl,
    };
    fn putImpl(_: *anyopaque, _: Receipt) anyerror!void {}
    fn removeImpl(_: *anyopaque, _: []const u8) anyerror!void {}
    fn getImpl(ptr: *anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!?Receipt {
        const self: *FakeReceipts = @ptrCast(@alignCast(ptr));
        const r = self.map.get(name) orelse return null;
        return Receipt{
            .name = try allocator.dupe(u8, r.name),
            .version = try allocator.dupe(u8, r.version),
        };
    }
    fn listImpl(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]Receipt {
        const self: *FakeReceipts = @ptrCast(@alignCast(ptr));
        var list: std.ArrayList(Receipt) = .empty;
        errdefer {
            for (list.items) |r| {
                allocator.free(r.name);
                allocator.free(r.version);
            }
            list.deinit(allocator);
        }
        var it = self.map.valueIterator();
        while (it.next()) |r| try list.append(allocator, .{
            .name = try allocator.dupe(u8, r.name),
            .version = try allocator.dupe(u8, r.version),
        });
        return list.toOwnedSlice(allocator);
    }
};

fn freePlans(a: std.mem.Allocator, ps: []Plan) void {
    for (ps) |p| freePlan(a, p);
    a.free(ps);
}

test "plan: only-name with newer index version is selected" {
    const a = std.testing.allocator;
    var fc = FakeCatalog{};
    defer fc.map.deinit(a);
    try fc.map.put(a, "xz", .{ .name = "xz", .version = Version.init("5.8.3") });
    var fr = FakeReceipts{ .gpa = a };
    defer fr.deinit();
    try fr.map.put(a, "xz", .{ .name = "xz", .version = "5.8.0" });
    const ps = try plan(a, fc.port(), fr.port(), "xz");
    defer freePlans(a, ps);
    try std.testing.expectEqual(@as(usize, 1), ps.len);
    try std.testing.expectEqualStrings("xz", ps[0].name);
    try std.testing.expectEqualStrings("5.8.0", ps[0].old_version);
    try std.testing.expectEqualStrings("5.8.3", ps[0].new_version);
}

test "plan: up-to-date keg is not selected" {
    const a = std.testing.allocator;
    var fc = FakeCatalog{};
    defer fc.map.deinit(a);
    try fc.map.put(a, "xz", .{ .name = "xz", .version = Version.init("5.8.3") });
    var fr = FakeReceipts{ .gpa = a };
    defer fr.deinit();
    try fr.map.put(a, "xz", .{ .name = "xz", .version = "5.8.3" });
    const ps = try plan(a, fc.port(), fr.port(), null);
    defer freePlans(a, ps);
    try std.testing.expectEqual(@as(usize, 0), ps.len);
}

test "plan: only-name not installed errors" {
    const a = std.testing.allocator;
    var fc = FakeCatalog{};
    defer fc.map.deinit(a);
    var fr = FakeReceipts{ .gpa = a };
    defer fr.deinit();
    try std.testing.expectError(error.NotInstalled, plan(a, fc.port(), fr.port(), "ghost"));
}

test "plan: all scan skips kegs dropped from the index" {
    const a = std.testing.allocator;
    var fc = FakeCatalog{};
    defer fc.map.deinit(a);
    try fc.map.put(a, "xz", .{ .name = "xz", .version = Version.init("5.8.3") });
    var fr = FakeReceipts{ .gpa = a };
    defer fr.deinit();
    try fr.map.put(a, "xz", .{ .name = "xz", .version = "5.8.0" });
    try fr.map.put(a, "old", .{ .name = "old", .version = "1.0" });
    const ps = try plan(a, fc.port(), fr.port(), null);
    defer freePlans(a, ps);
    try std.testing.expectEqual(@as(usize, 1), ps.len);
    try std.testing.expectEqualStrings("xz", ps[0].name);
}
