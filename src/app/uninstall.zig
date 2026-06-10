//! App use-case: uninstall an installed keg.
//!
//! Reverses what install did, in the safe order:
//!   1. unlink the keg's symlinks from the prefix (bin/lib/… + opt/<name>),
//!   2. remove the keg's Cellar dir (`<cellar>/<name>` and everything under it),
//!   3. drop its receipt.
//!
//! Returns `error.NotInstalled` if no receipt exists for `name`.
//!
//! Zig 0.16 API: `std.Io.Dir.deleteTree(io, sub_path)` is the recursive
//! directory delete (rm -rf). Its error set (`DeleteTreeError`) has no
//! `FileNotFound`: it already returns success when the path is absent, so the
//! step is idempotent without us catching anything.
const std = @import("std");
const ReceiptStore = @import("../ports/receipt_store.zig").ReceiptStore;
const linker = @import("../adapters/linker.zig");

pub const Uninstaller = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    receipts: ReceiptStore,
    prefix_abs: []const u8, // absolute <prefix>
    cellar_dir: std.Io.Dir, // open <prefix>/Cellar (to remove the keg dir)

    /// Unlink the keg, remove its Cellar dir, and drop its receipt.
    /// `error.NotInstalled` if absent.
    pub fn uninstall(self: Uninstaller, name: []const u8) !void {
        const r = (try self.receipts.get(self.allocator, name)) orelse return error.NotInstalled;
        defer {
            self.allocator.free(r.name);
            self.allocator.free(r.version);
        }
        try linker.unlink(self.io, self.allocator, self.prefix_abs, name);
        // Remove <cellar>/<name> recursively (whole formula dir incl. version).
        // deleteTree is a no-op if the path is already gone.
        try self.cellar_dir.deleteTree(self.io, name);
        try self.receipts.remove(name);
    }
};

// ---------------------------------------------------------------------------
// Test (offline, tmpDir + in-memory fake store).
// ---------------------------------------------------------------------------

const Receipt = @import("../ports/receipt_store.zig").Receipt;

/// In-memory ReceiptStore fake. `get` returns owned (duped) strings.
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

test "uninstall: removes links, keg dir, and receipt; errors when absent" {
    const a = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // prefix = tmp dir; Cellar lives under it.
    const prefix_abs = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(prefix_abs);

    // Build a fake keg: <prefix>/Cellar/pkg/1.0/bin/hello
    var keg_bin = try tmp.dir.createDirPathOpen(io, "Cellar/pkg/1.0/bin", .{});
    keg_bin.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "Cellar/pkg/1.0/bin/hello", .data = "hello-bin" });

    const keg_abs = try std.fs.path.join(a, &.{ prefix_abs, "Cellar", "pkg", "1.0" });
    defer a.free(keg_abs);

    // Link it into the prefix and record a receipt.
    try linker.link(io, a, prefix_abs, keg_abs, "pkg");

    var cellar_dir = try tmp.dir.openDir(io, "Cellar", .{ .iterate = true });
    defer cellar_dir.close(io);

    var receipts = FakeReceipts{ .gpa = a };
    defer receipts.deinit();
    try receipts.port().put(.{ .name = "pkg", .version = "1.0" });

    const uninstaller = Uninstaller{
        .io = io,
        .allocator = a,
        .receipts = receipts.port(),
        .prefix_abs = prefix_abs,
        .cellar_dir = cellar_dir,
    };

    // Sanity: link present before uninstall.
    {
        const got = try tmp.dir.readFileAlloc(io, "bin/hello", a, .unlimited);
        defer a.free(got);
        try std.testing.expectEqualStrings("hello-bin", got);
    }

    try uninstaller.uninstall("pkg");

    // Link gone.
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "bin/hello", .{}));
    // Keg dir gone.
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "Cellar/pkg", .{}));
    // Receipt gone.
    try std.testing.expect((try receipts.port().get(a, "pkg")) == null);

    // Uninstalling something not installed -> error.NotInstalled.
    try std.testing.expectError(error.NotInstalled, uninstaller.uninstall("ghost"));
}
