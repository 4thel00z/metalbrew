# metalbrew M3 — `upgrade` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) tracking.

**Goal:** Add `metalbrew upgrade [<formula>]` — compare each installed keg's version against the cached index and reinstall the ones with a newer version available.

**Architecture:** Reuse the M2 pipeline. The decision ("which installed kegs are out of date") is a **pure planner** over two existing ports (`PackageCatalog`, `ReceiptStore`) — fully unit-testable with fakes. Execution (uninstall old → install new) is thin orchestration in the composition root, reusing `Uninstaller` + `Installer`, verified end-to-end.

**Tech Stack:** Zig 0.16.0, existing M2 adapters. No new ports or adapters.

---

## Existing seams M3 builds on (verified against the code)

- `src/domain/version.zig` — `Version.init(raw)`, `Version.order(a, b) std.math.Order` (segment compare; tested).
- `src/ports/catalog.zig` — `PackageCatalog.get(allocator, name) anyerror!?Formula`; `Formula.version: Version` (`.raw`).
- `src/ports/receipt_store.zig` — `Receipt{ name, version }`; `ReceiptStore.get/list/put/remove`. `get`/`list` hand back **owned (duped)** strings the caller must free.
- `src/app/install.zig` — `Installer{ io, allocator, catalog, fetcher, receipts, cellar_dir, cellar_abs, prefix_abs, tags }`, `.install(name) ![]const []const u8` (skips kegs whose receipt is present).
- `src/app/uninstall.zig` — `Uninstaller{ io, allocator, receipts, prefix_abs, cellar_dir }`, `.uninstall(name) !void` (`error.NotInstalled` if absent).
- `src/adapters/cli.zig` — `Command` union; `parse(args)`.
- `src/main.zig` — `.install`/`.uninstall`/`.list` arms show how to build the catalog (`loadCachedCatalog`), receipts dir, cellar dir, `GhcrFetcher`, and `os_tag.detectArm64Tag`.

Ownership note: a `Formula` returned by `catalog.get` is owned by the catalog (arena in prod, borrowed in fakes) — do **not** free its fields (mirrors `install.zig`). Only `Receipt` strings from `receipts.get/list` must be freed.

---

## Task M3-1: `upgrade` pure planner + tests

**Files:**
- Create: `src/app/upgrade.zig`
- Modify: `src/root.zig` (`pub const upgrade = @import("app/upgrade.zig");` under `app`, and `_ = @import("app/upgrade.zig");` in the test block)

- [ ] **Step 1: Write the planner with tests**

```zig
//! App use-case: plan which installed kegs have a newer version in the index.
//!
//! Pure decision over two ports — no install/uninstall side effects here, so it
//! is fully unit-testable with fakes. The composition root executes a plan by
//! reinstalling each entry (uninstall old -> install new).
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

/// Return the installed kegs whose index version is newer than the installed one.
/// `only != null` restricts to that single keg (error.NotInstalled if it has no
/// receipt; error.UnknownFormula if the index doesn't know it). `only == null`
/// scans all installed receipts and silently skips any the index no longer lists.
/// Caller owns the returned slice and every string in it.
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
        defer { allocator.free(r.name); allocator.free(r.version); }
        const f = (try catalog.get(allocator, name)) orelse return error.UnknownFormula;
        if (isNewer(r.version, f.version)) {
            try out.append(allocator, try makePlan(allocator, name, r.version, f.version.raw));
        }
    } else {
        const all = try receipts.list(allocator);
        defer {
            for (all) |r| { allocator.free(r.name); allocator.free(r.version); }
            allocator.free(all);
        }
        for (all) |r| {
            const f = (try catalog.get(allocator, r.name)) orelse continue; // dropped from index
            if (isNewer(r.version, f.version)) {
                try out.append(allocator, try makePlan(allocator, r.name, r.version, f.version.raw));
            }
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

// ---- tests ----
const FakeCatalog = @import("../ports/catalog.zig").FakeCatalog;
const Receipt = @import("../ports/receipt_store.zig").Receipt;

/// In-memory ReceiptStore fake whose get/list hand back owned (duped) strings.
const FakeReceipts = struct {
    map: std.StringHashMapUnmanaged(Receipt) = .empty,
    gpa: std.mem.Allocator,

    fn deinit(self: *FakeReceipts) void {
        self.map.deinit(self.gpa);
    }
    fn port(self: *FakeReceipts) ReceiptStore {
        return .{ .ptr = self, .vtable = &vtable };
    }
    const vtable = ReceiptStore.VTable{ .put = putImpl, .get = getImpl, .list = listImpl, .remove = removeImpl };
    fn putImpl(_: *anyopaque, _: Receipt) anyerror!void {}
    fn removeImpl(_: *anyopaque, _: []const u8) anyerror!void {}
    fn getImpl(ptr: *anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!?Receipt {
        const self: *FakeReceipts = @ptrCast(@alignCast(ptr));
        const r = self.map.get(name) orelse return null;
        return Receipt{ .name = try allocator.dupe(u8, r.name), .version = try allocator.dupe(u8, r.version) };
    }
    fn listImpl(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]Receipt {
        const self: *FakeReceipts = @ptrCast(@alignCast(ptr));
        var out: std.ArrayList(Receipt) = .empty;
        var it = self.map.valueIterator();
        while (it.next()) |r| try out.append(allocator, .{
            .name = try allocator.dupe(u8, r.name),
            .version = try allocator.dupe(u8, r.version),
        });
        return out.toOwnedSlice(allocator);
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
    // "old" is installed but no longer in the index.
    var fr = FakeReceipts{ .gpa = a };
    defer fr.deinit();
    try fr.map.put(a, "xz", .{ .name = "xz", .version = "5.8.0" });
    try fr.map.put(a, "old", .{ .name = "old", .version = "1.0" });

    const ps = try plan(a, fc.port(), fr.port(), null);
    defer freePlans(a, ps);
    try std.testing.expectEqual(@as(usize, 1), ps.len);
    try std.testing.expectEqualStrings("xz", ps[0].name);
}
```

- [ ] **Step 2** — wire `root.zig`; `zig build test --summary all` → +4 tests, no leaks (testing.allocator).
- [ ] **Step 3** — commit: `feat(app): upgrade planner (version-diff installed vs index)`.

> NOTE: confirm `std.StringHashMapUnmanaged.valueIterator()` exists on 0.16; if not, use `iterator()` and read `entry.value_ptr.*`. The `FakeReceipts` here mirrors the one already in `src/app/uninstall.zig` — copy that file's working version if signatures differ.

---

## Task M3-2: CLI `upgrade` + composition root + e2e

**Files:**
- Modify: `src/adapters/cli.zig`
- Modify: `src/main.zig`
- Modify: `src/root.zig` (only if needed)

- [ ] **Step 1: Add the `upgrade` command variant** in `src/adapters/cli.zig`.

`upgrade` takes an OPTIONAL formula (`metalbrew upgrade` = all, `metalbrew upgrade xz` = one). Add to the `Command` union:
```zig
    upgrade: ?[]const u8,
```
In `parse`, after the `list` line:
```zig
        if (std.mem.eql(u8, cmd, "upgrade")) return .{ .upgrade = if (args.len >= 2) args[1] else null };
```
Add tests mirroring the existing style:
```zig
    try std.testing.expect(Command.parse(&.{"upgrade"}).upgrade == null);
    try std.testing.expectEqualStrings("xz", Command.parse(&.{ "upgrade", "xz" }).upgrade.?);
```

- [ ] **Step 2: Add the `.upgrade` arm** to the `switch (cmd)` in `src/main.zig`, after `.uninstall`.

It builds the same collaborators as `.install` (catalog via `loadCachedCatalog`, receipts dir, cellar dir, `GhcrFetcher`, `os_tag.detectArm64Tag`, `tags`), plus an `Uninstaller`, then: compute the plan, and for each entry reinstall (uninstall → install). Add `const upgrade_app = @import("app/upgrade.zig");` to the imports.

```zig
        .upgrade => |only| {
            var cat = (try loadCachedCatalog(init, paths)) orelse {
                try w.writeAll("No index. Run `metalbrew update` first.\n");
                return;
            };
            defer cat.deinit();

            const cellar_abs = try std.fs.path.join(a, &.{ paths.prefix, "Cellar" });
            const cellar_dir = try std.Io.Dir.cwd().createDirPathOpen(io, cellar_abs, .{});
            const receipts_abs = try std.fs.path.join(a, &.{ paths.prefix, "var", "metalbrew", "receipts" });
            const receipts_dir = try std.Io.Dir.cwd().createDirPathOpen(io, receipts_abs, .{});
            var receipts = FsReceiptStore{ .io = io, .dir = receipts_dir };

            const plans = upgrade_app.plan(a, cat.port(), receipts.port(), only) catch |e| switch (e) {
                error.NotInstalled => {
                    try w.print("'{s}' is not installed.\n", .{only.?});
                    return;
                },
                error.UnknownFormula => {
                    try w.print("No formula named '{s}'. Try `metalbrew update`.\n", .{only.?});
                    return;
                },
                else => return e,
            };
            if (plans.len == 0) {
                try w.writeAll("Everything up to date.\n");
                return;
            }

            const http = try HttpClient.init(init.gpa);
            defer http.deinit();
            var fetcher = GhcrFetcher{ .http = http };
            const tag = os_tag.detectArm64Tag(io, a) catch |e| switch (e) {
                error.UnsupportedMacOS => { try w.writeAll("Unsupported macOS version (no arm64 bottle tag).\n"); return; },
                else => return e,
            };
            const tags = [_][]const u8{tag.text};

            const uninstaller = uninstall_app.Uninstaller{
                .io = io, .allocator = a, .receipts = receipts.port(),
                .prefix_abs = paths.prefix, .cellar_dir = cellar_dir,
            };
            const installer = install_app.Installer{
                .io = io, .allocator = a, .catalog = cat.port(), .fetcher = fetcher.port(),
                .receipts = receipts.port(), .cellar_dir = cellar_dir, .cellar_abs = cellar_abs,
                .prefix_abs = paths.prefix, .tags = &tags,
            };

            for (plans) |p| {
                try uninstaller.uninstall(p.name);     // drop old keg + receipt
                _ = try installer.install(p.name);      // reinstall current (receipt now absent)
                try w.print("Upgraded {s} {s} -> {s}\n", .{ p.name, p.old_version, p.new_version });
            }
        },
```

- [ ] **Step 3: Add `upgrade` to the help text** in `printHelp` (a line like `metalbrew upgrade [<formula>]   Upgrade installed packages`).

- [ ] **Step 4: Build + tests** — `zig build`, `zig build test --summary all` (cli parse +1 test passes), `METALBREW_SKIP_NET=1 zig build test`.

- [ ] **Step 5: End-to-end verification (real, in a throwaway prefix)** — force an "old" install and confirm `upgrade` reinstalls:

```bash
zig build
PREFIX="$(mktemp -d)/mb"; export METALBREW_PREFIX="$PREFIX"
./zig-out/bin/metalbrew update >/dev/null
./zig-out/bin/metalbrew install xz
# Force the receipt to look old so upgrade has work to do:
printf '{"name":"xz","version":"0.0.1"}' > "$PREFIX/var/metalbrew/receipts/xz.json"
./zig-out/bin/metalbrew upgrade xz          # expect: Upgraded xz 0.0.1 -> 5.8.3
./zig-out/bin/metalbrew list                # expect: xz 5.8.3
"$PREFIX/bin/xz" --version                  # expect: still runs (reinstalled + relocated)
./zig-out/bin/metalbrew upgrade             # expect: Everything up to date.
rm -rf "$(dirname "$PREFIX")"
```
All expectations must hold (the forced-old receipt proves the version-diff + reinstall path; the second `upgrade` proves the up-to-date path).

- [ ] **Step 6: Commit** — `feat(cli): wire upgrade command`.

---

## Self-Review
- **Spec coverage:** `upgrade` (all) + `upgrade <name>` → M3-2; version-diff vs index → M3-1 planner (`isNewer` via tested `Version.order`); reinstall newer → M3-2 execution reusing `Uninstaller`+`Installer`. ✅
- **Placeholders:** none — full code in every step.
- **Type consistency:** `Plan{name, old_version, new_version}` used identically in planner and main; `plan(allocator, catalog, receipts, only)` signature matches the main call; `Command.upgrade: ?[]const u8` matches `parse` and the main arm.
- **0.16 risk:** `valueIterator()` (noted), and the `FakeReceipts` mirrors `uninstall.zig`'s — copy the working one if signatures drift.
