//! App use-case: transitive install.
//!
//! Composes the whole pipeline for a root formula and all its runtime deps
//! (deps first, root last):
//!
//!   resolve_deps -> for each name not already installed:
//!     catalog.get -> pickBottle (tag fallback) -> fetcher.fetch
//!       -> pour (untar into Cellar) -> relocate -> link -> receipts.put
//!
//! Already-installed kegs (a receipt is present) are skipped. Returns the
//! names that were newly installed, owned by `allocator`.
const std = @import("std");
const PackageCatalog = @import("../ports/catalog.zig").PackageCatalog;
const BottleFetcher = @import("../ports/bottle_fetcher.zig").BottleFetcher;
const ReceiptStore = @import("../ports/receipt_store.zig").ReceiptStore;
const BottleSpec = @import("../domain/formula.zig").BottleSpec;
const resolve_deps = @import("resolve_deps.zig");
const pour = @import("../adapters/pour.zig");
const relocator = @import("../adapters/relocator.zig");
const linker = @import("../adapters/linker.zig");

/// All the collaborators the install pipeline needs, bundled so call signatures
/// stay sane. Held by value (ports are fat pointers; dirs/strings are borrowed).
pub const Installer = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    catalog: PackageCatalog,
    fetcher: BottleFetcher,
    receipts: ReceiptStore,
    cellar_dir: std.Io.Dir, // open <prefix>/Cellar
    cellar_abs: []const u8, // absolute <prefix>/Cellar
    prefix_abs: []const u8, // absolute <prefix>
    tags: []const []const u8, // fallback tag list, current first

    /// Install `root_name` and all its transitive runtime deps (deps first).
    /// Skips any already-installed keg (receipt present). Returns the names
    /// newly installed (each string + the slice owned by `self.allocator`).
    pub fn install(self: Installer, root_name: []const u8) ![]const []const u8 {
        const order = try resolve_deps.run(self.allocator, self.catalog, root_name);
        defer self.allocator.free(order);

        var installed: std.ArrayList([]const u8) = .empty;
        // On any error, free what we already appended so the caller leaks nothing.
        errdefer {
            for (installed.items) |n| self.allocator.free(n);
            installed.deinit(self.allocator);
        }

        for (order) |name| {
            // Already installed? Free the receipt the store handed us and skip.
            if (try self.receipts.get(self.allocator, name)) |r| {
                self.allocator.free(r.name);
                self.allocator.free(r.version);
                continue;
            }

            const formula = (try self.catalog.get(self.allocator, name)) orelse
                return error.UnknownFormula;
            const bottle = pickBottle(formula, self.tags) orelse
                return error.NoBottleForPlatform;

            const bytes = try self.fetcher.fetch(self.allocator, bottle.url, bottle.sha256);
            defer self.allocator.free(bytes);

            try pour.pour(self.io, self.allocator, self.cellar_dir, bytes);

            const keg_abs = try std.fs.path.join(
                self.allocator,
                &.{ self.cellar_abs, name, formula.version.raw },
            );
            defer self.allocator.free(keg_abs);

            try relocator.relocate(self.io, self.allocator, keg_abs, self.prefix_abs, self.cellar_abs);
            try linker.link(self.io, self.allocator, self.prefix_abs, keg_abs, name);

            try self.receipts.put(.{ .name = name, .version = formula.version.raw });
            try installed.append(self.allocator, try self.allocator.dupe(u8, name));
        }

        return installed.toOwnedSlice(self.allocator);
    }
};

/// First bottle matching any tag in `tags` (current platform first).
fn pickBottle(formula: anytype, tags: []const []const u8) ?BottleSpec {
    for (tags) |t| if (formula.bottleFor(t)) |b| return b;
    return null;
}

// ---------------------------------------------------------------------------
// Test (offline, with fakes + two embedded bottle fixtures).
// ---------------------------------------------------------------------------

const Formula = @import("../domain/formula.zig").Formula;
const Version = @import("../domain/version.zig").Version;
const Receipt = @import("../ports/receipt_store.zig").Receipt;
const FakeCatalog = @import("../ports/catalog.zig").FakeCatalog;

/// Fetcher fake: returns embedded fixture bytes keyed by url. Ignores sha.
const FakeFetcher = struct {
    fn fetchImpl(ptr: *anyopaque, allocator: std.mem.Allocator, url: []const u8, sha256_hex: []const u8) anyerror![]u8 {
        _ = ptr;
        _ = sha256_hex;
        const src = if (std.mem.eql(u8, url, "pkg-url"))
            @embedFile("../testdata/mini-bottle.tar.gz")
        else if (std.mem.eql(u8, url, "dep-url"))
            @embedFile("../testdata/dep-bottle.tar.gz")
        else
            return error.UnknownUrl;
        return allocator.dupe(u8, src);
    }
    const vtable = BottleFetcher.VTable{ .fetch = fetchImpl };
    fn port(self: *FakeFetcher) BottleFetcher {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

/// In-memory ReceiptStore fake. `get` returns owned (duped) strings, matching
/// the real fs store's ownership contract.
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
        var it = self.map.valueIterator();
        while (it.next()) |v| try list.append(allocator, v.*);
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

fn freeNames(a: std.mem.Allocator, names: []const []const u8) void {
    for (names) |n| a.free(n);
    a.free(names);
}

test "install: transitive (dep first) + skip-if-installed" {
    const a = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // prefix = tmp dir; Cellar lives under it.
    const prefix_abs = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(prefix_abs);
    var cellar_dir = try tmp.dir.createDirPathOpen(io, "Cellar", .{});
    defer cellar_dir.close(io);
    const cellar_abs = try std.fs.path.join(a, &.{ prefix_abs, "Cellar" });
    defer a.free(cellar_abs);

    // Catalog: pkg(1.0) -> dep(2.0). Bottles tagged arm64_tahoe.
    var cat = FakeCatalog{};
    defer cat.map.deinit(a);
    try cat.map.put(a, "pkg", .{
        .name = "pkg",
        .version = Version.init("1.0"),
        .dependencies = &.{.{ .name = "dep" }},
        .bottles = &.{.{ .tag = "arm64_tahoe", .url = "pkg-url", .sha256 = "deadbeef" }},
    });
    try cat.map.put(a, "dep", .{
        .name = "dep",
        .version = Version.init("2.0"),
        .bottles = &.{.{ .tag = "arm64_tahoe", .url = "dep-url", .sha256 = "deadbeef" }},
    });

    var fetcher = FakeFetcher{};
    var receipts = FakeReceipts{ .gpa = a };
    defer receipts.deinit();

    const installer = Installer{
        .io = io,
        .allocator = a,
        .catalog = cat.port(),
        .fetcher = fetcher.port(),
        .receipts = receipts.port(),
        .cellar_dir = cellar_dir,
        .cellar_abs = cellar_abs,
        .prefix_abs = prefix_abs,
        .tags = &.{"arm64_tahoe"},
    };

    // 1. First install: both, dep before pkg.
    {
        const got = try installer.install("pkg");
        defer freeNames(a, got);
        try std.testing.expectEqual(@as(usize, 2), got.len);
        try std.testing.expectEqualStrings("dep", got[0]);
        try std.testing.expectEqualStrings("pkg", got[1]);
    }

    // 2. Both linked into the prefix + receipts exist.
    {
        const w = try tmp.dir.readFileAlloc(io, "bin/world", a, .unlimited);
        defer a.free(w);
        try std.testing.expectEqualStrings("dep-bin", w);

        const h = try tmp.dir.readFileAlloc(io, "bin/hello", a, .unlimited);
        defer a.free(h);
        try std.testing.expectEqualStrings("hello-bin", h);

        const rp = (try receipts.port().get(a, "pkg")).?;
        defer {
            a.free(rp.name);
            a.free(rp.version);
        }
        try std.testing.expectEqualStrings("1.0", rp.version);
        const rd = (try receipts.port().get(a, "dep")).?;
        defer {
            a.free(rd.name);
            a.free(rd.version);
        }
        try std.testing.expectEqualStrings("2.0", rd.version);
    }

    // 3. Re-install: everything skipped -> empty list, no error.
    {
        const got = try installer.install("pkg");
        defer freeNames(a, got);
        try std.testing.expectEqual(@as(usize, 0), got.len);
    }
}
