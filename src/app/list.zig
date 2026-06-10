//! App use-case: list installed kegs.
//!
//! Returns the receipts from the store sorted by name ascending so callers
//! (the CLI) get a stable, human-friendly ordering.
const std = @import("std");
const ReceiptStore = @import("../ports/receipt_store.zig").ReceiptStore;
const Receipt = @import("../ports/receipt_store.zig").Receipt;

/// Return installed receipts sorted by name ascending. Caller owns the slice
/// and each receipt's `name`/`version` strings (allocated by `allocator`).
pub fn run(allocator: std.mem.Allocator, receipts: ReceiptStore) ![]Receipt {
    const all = try receipts.list(allocator);
    std.mem.sort(Receipt, all, {}, lessByName);
    return all;
}

fn lessByName(_: void, a: Receipt, b: Receipt) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

// ---------------------------------------------------------------------------
// Test (offline, in-memory fake store).
// ---------------------------------------------------------------------------

/// In-memory ReceiptStore fake. `get`/`list` hand back owned (duped) strings,
/// matching the real fs store's ownership contract.
const FakeReceipts = struct {
    map: std.StringHashMapUnmanaged(Receipt) = .empty,
    gpa: std.mem.Allocator,

    fn deinit(self: *FakeReceipts) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.name);
            self.gpa.free(e.value_ptr.version);
        }
        self.map.deinit(self.gpa);
    }

    fn putImpl(ptr: *anyopaque, r: Receipt) anyerror!void {
        const self: *FakeReceipts = @ptrCast(@alignCast(ptr));
        const key = try self.gpa.dupe(u8, r.name);
        errdefer self.gpa.free(key);
        const name = try self.gpa.dupe(u8, r.name);
        errdefer self.gpa.free(name);
        const version = try self.gpa.dupe(u8, r.version);
        try self.map.put(self.gpa, key, .{ .name = name, .version = version });
    }
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
        while (it.next()) |v| try list.append(allocator, .{
            .name = try allocator.dupe(u8, v.name),
            .version = try allocator.dupe(u8, v.version),
        });
        return list.toOwnedSlice(allocator);
    }
    fn removeImpl(ptr: *anyopaque, name: []const u8) anyerror!void {
        const self: *FakeReceipts = @ptrCast(@alignCast(ptr));
        if (self.map.fetchRemove(name)) |kv| {
            self.gpa.free(kv.key);
            self.gpa.free(kv.value.name);
            self.gpa.free(kv.value.version);
        }
    }
    const vtable = ReceiptStore.VTable{
        .put = putImpl,
        .get = getImpl,
        .list = listImpl,
        .remove = removeImpl,
    };
    fn port(self: *FakeReceipts) ReceiptStore {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

test "list: returns receipts sorted by name" {
    const a = std.testing.allocator;

    var receipts = FakeReceipts{ .gpa = a };
    defer receipts.deinit();

    // Insert out of order; list.run must sort wget before xz.
    try receipts.port().put(.{ .name = "xz", .version = "5.8.3" });
    try receipts.port().put(.{ .name = "wget", .version = "1.25.0" });

    const got = try run(a, receipts.port());
    defer {
        for (got) |r| {
            a.free(r.name);
            a.free(r.version);
        }
        a.free(got);
    }

    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("wget", got[0].name);
    try std.testing.expectEqualStrings("1.25.0", got[0].version);
    try std.testing.expectEqualStrings("xz", got[1].name);
    try std.testing.expectEqualStrings("5.8.3", got[1].version);
}
