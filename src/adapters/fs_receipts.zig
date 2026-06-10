//! Adapter: ReceiptStore backed by one JSON file per installed keg.
//!
//! Layout: `<receipts_dir>/<name>.json` containing `{"name":...,"version":...}`.
//! Holds an `io` and an already-open receipts directory handle (the composition
//! root opens/creates it; tests pass a `std.testing.tmpDir` handle). This mirrors
//! the Dir-handle design of FsIndexCache.
//!
//! Zig 0.16 APIs used:
//!   * `dir.writeFile(io, .{ .sub_path, .data })` — write a receipt file.
//!   * `dir.readFileAlloc(io, sub_path, gpa, .unlimited)` — read it back
//!     (FileNotFound -> null).
//!   * `dir.deleteFile(io, sub_path)` — remove it (FileNotFound ok).
//!   * `dir.walk(allocator)` / `walker.next(io)` — iterate entries; filter
//!     `.kind == .file` with a `.json` suffix.
//!   * `std.json.Stringify.valueAlloc` to serialize a Receipt to JSON, and
//!     `std.json.parseFromSlice(std.json.Value, ...)` then `.object.get(...).?.string`.
const std = @import("std");
const ReceiptStore = @import("../ports/receipt_store.zig").ReceiptStore;
const Receipt = @import("../ports/receipt_store.zig").Receipt;

pub const FsReceiptStore = struct {
    io: std.Io,
    dir: std.Io.Dir,

    pub fn port(self: *FsReceiptStore) ReceiptStore {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = ReceiptStore.VTable{
        .put = putImpl,
        .get = getImpl,
        .list = listImpl,
        .remove = removeImpl,
    };

    fn putImpl(ptr: *anyopaque, r: Receipt) anyerror!void {
        const self: *FsReceiptStore = @ptrCast(@alignCast(ptr));
        // Serialize the Receipt struct to `{"name":...,"version":...}`; the
        // stringifier escapes quotes/backslashes correctly.
        const bytes = try std.json.Stringify.valueAlloc(std.heap.page_allocator, r, .{});
        defer std.heap.page_allocator.free(bytes);

        const sub = try fileName(std.heap.page_allocator, r.name);
        defer std.heap.page_allocator.free(sub);
        try self.dir.writeFile(self.io, .{ .sub_path = sub, .data = bytes });
    }

    fn getImpl(ptr: *anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!?Receipt {
        const self: *FsReceiptStore = @ptrCast(@alignCast(ptr));
        const sub = try fileName(allocator, name);
        defer allocator.free(sub);
        const bytes = self.dir.readFileAlloc(self.io, sub, allocator, .unlimited) catch |e| switch (e) {
            error.FileNotFound => return null,
            else => return e,
        };
        defer allocator.free(bytes);
        return try parseReceipt(allocator, bytes);
    }

    fn listImpl(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]Receipt {
        const self: *FsReceiptStore = @ptrCast(@alignCast(ptr));

        var out: std.ArrayList(Receipt) = .empty;
        errdefer {
            for (out.items) |r| {
                allocator.free(r.name);
                allocator.free(r.version);
            }
            out.deinit(allocator);
        }

        var walker = try self.dir.walk(allocator);
        defer walker.deinit();

        while (try walker.next(self.io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".json")) continue;
            const bytes = try self.dir.readFileAlloc(self.io, entry.path, allocator, .unlimited);
            defer allocator.free(bytes);
            try out.append(allocator, try parseReceipt(allocator, bytes));
        }

        return out.toOwnedSlice(allocator);
    }

    fn removeImpl(ptr: *anyopaque, name: []const u8) anyerror!void {
        const self: *FsReceiptStore = @ptrCast(@alignCast(ptr));
        const sub = try fileName(std.heap.page_allocator, name);
        defer std.heap.page_allocator.free(sub);
        self.dir.deleteFile(self.io, sub) catch |e| switch (e) {
            error.FileNotFound => return,
            else => return e,
        };
    }
};

/// `<name>.json` allocated with `allocator`.
fn fileName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.json", .{name});
}

/// Parse `{"name":...,"version":...}`; both fields duped with `allocator`.
fn parseReceipt(allocator: std.mem.Allocator, bytes: []const u8) !Receipt {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    const name = try allocator.dupe(u8, obj.get("name").?.string);
    errdefer allocator.free(name);
    const version = try allocator.dupe(u8, obj.get("version").?.string);
    return .{ .name = name, .version = version };
}

// ---------------------------------------------------------------------------
// Tests (offline, tmpDir).
// ---------------------------------------------------------------------------

test "fs receipts round-trip" {
    const a = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = FsReceiptStore{ .io = io, .dir = tmp.dir };
    const rs = store.port();
    try rs.put(.{ .name = "xz", .version = "5.8.3" });
    try rs.put(.{ .name = "wget", .version = "1.25.0" });
    const all = try rs.list(a);
    defer {
        for (all) |r| {
            a.free(r.name);
            a.free(r.version);
        }
        a.free(all);
    }
    try std.testing.expectEqual(@as(usize, 2), all.len);
    const one = (try rs.get(a, "xz")).?;
    defer {
        a.free(one.name);
        a.free(one.version);
    }
    try std.testing.expectEqualStrings("5.8.3", one.version);
    try rs.remove("xz");
    try std.testing.expect((try rs.get(a, "xz")) == null);
}
