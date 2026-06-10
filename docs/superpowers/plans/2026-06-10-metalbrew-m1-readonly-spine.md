# metalbrew M1 — Read-Only Spine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the read-only spine of metalbrew — a Zig reimplementation of Homebrew that fetches the formulae.brew.sh JSON index, caches it, and answers `update`, `info`, `search`, and `deps` with full transitive dependency resolution. No installs yet (that is M2).

**Architecture:** Hexagonal (ports & adapters) with a DDD domain core. The domain (value objects + dependency-resolution service) is pure and I/O-free. Application use-cases orchestrate the domain through two driven ports — `PackageCatalog` and `IndexCache`. Adapters implement those ports over `std.http` and `std.fs`; a `Cli` driving adapter parses argv. `main.zig` is the composition root. Test doubles satisfy the ports so every use-case is tested without network or disk.

**Tech Stack:** Zig **0.16.0** (verified installed), pure-Zig `std.http.Client` with `std.Io.Threaded`, `std.json` dynamic `Value` parsing, `std.fs` for the cache. Target: macOS arm64. Prefix: `~/.metalbrew` (no sudo).

---

## Verified 0.16 API notes (load-bearing — confirmed via compile-spike against the live API)

These exact patterns compiled and ran on the target machine. Do not "fix" them from memory of older Zig.

- **HTTP client construction** needs an `Io`:
  ```zig
  var threaded: std.Io.Threaded = .init(allocator, .{});
  defer threaded.deinit();
  const io = threaded.io();
  var client: std.http.Client = .{ .allocator = allocator, .io = io };
  defer client.deinit();
  ```
- **GET a body into memory** uses an allocating writer:
  ```zig
  var aw: std.Io.Writer.Allocating = .init(allocator);
  defer aw.deinit();
  const res = try client.fetch(.{
      .location = .{ .url = url },
      .response_writer = &aw.writer,
  });
  // res.status is an http.Status enum; @intFromEnum(res.status) == 200
  const body: []u8 = aw.written();
  ```
- **JSON** — use dynamic `Value`, not typed structs (the brew API has dozens of fields):
  ```zig
  const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
  defer parsed.deinit();
  const obj = parsed.value.object;            // std.json.ObjectMap
  const name = obj.get("name").?.string;       // []const u8
  const deps = obj.get("dependencies").?.array; // std.json.Array, .items
  ```
- **Build system** (`zig init` 0.16 shape): `b.addModule`, `b.createModule`, `b.addExecutable(.{ .root_module = ... })`, `b.addTest(.{ .root_module = ... })`, a `test` step depending on `b.addRunArtifact(...)`.
- Real datum from the spike: `GET https://formulae.brew.sh/api/formula/wget.json` → 200, `name == "wget"`, `dependencies == ["libidn2", ...]` (4 entries).

### CORRECTIONS discovered during Task 1 (0.16 reality — supersede the snippets below where they conflict)

These were verified against the installed stdlib while implementing Task 1. **Treat all code snippets in this plan as intent; the exact stdlib calls below win.**

- **`std.fs.File` does NOT exist in 0.16** — `File` lives at `std.Io.File`. Get stdout via:
  ```zig
  var buf: [4096]u8 = undefined;
  var fw: std.Io.File.Writer = .init(.stdout(), io, &buf);
  const w = &fw.interface;        // *std.Io.Writer
  try w.writeAll("...");
  try w.flush();
  ```
- **`std.testing.refAllDeclsRecursive` does NOT exist in 0.16.** Only non-recursive `refAllDecls`, which will NOT discover tests in nested/imported modules → silent false-green. **TEST AGGREGATION RULE (mandatory):** `src/root.zig`'s `test {}` block must explicitly reference every source file so its tests run:
  ```zig
  test {
      _ = @import("config.zig");
      _ = @import("domain/version.zig");
      // ... one line per module file as each task lands it ...
  }
  ```
  Each task that creates a new `src/**.zig` file MUST add its `_ = @import("...");` line here, then confirm `zig build test` reports a higher test count.
- **Process args/env/io/allocators come from the main parameter `init: std.process.Init`** — `std.process.argsAlloc` / `std.process.getEnvMap` are gone. `Init` provides: `init.io` (Io), `init.gpa` (Allocator), `init.arena` (*ArenaAllocator), `init.environ_map` (*std.process.Environ.Map), `init.minimal.args` (command-line args). Signature: `pub fn main(init: std.process.Init) !void`.
- **Env var lookup** is `init.environ_map.get("NAME")` against `std.process.Environ.Map` (NOT `std.process.EnvMap`). Confirm the map's `get`/`put`/`init` API against the stdlib when writing config tests.
- **`std.ArrayList(T)` is the unmanaged variant** in 0.16: construct with `.empty`, call `list.append(allocator, item)` and `list.toOwnedSlice(allocator)` (allocator passed per-call). The plan's snippets already use this shape.
- **File reading:** `std.Io.File` has no `readToEndAlloc` by that exact name in 0.16 — verify the actual read-to-end API (likely via a `File.Reader` + `reader.readAlloc`/`allocRemaining`, or `std.Io.Dir` helpers) against the stdlib when implementing Task 8.

## File structure (hexagonal layout)

```
build.zig                          # composition wiring for compiler (module/exe/test)
build.zig.zon                      # package manifest
src/
├── main.zig                       # composition root: build adapters, run CLI
├── root.zig                       # module root; `test { _ = ... }` aggregates all tests
├── config.zig                     # Paths: prefix (~/.metalbrew) + cache dirs (infra config)
├── domain/
│   ├── version.zig                # Version value object: parse + order
│   ├── formula.zig                # Formula, Dependency, BottleSpec value objects
│   ├── platform.zig               # Tag value object (e.g. arm64_tahoe)
│   └── resolver.zig               # domain service: transitive deps + topo sort (pure)
├── ports/
│   ├── catalog.zig                # PackageCatalog port (vtable) + FakeCatalog test double
│   └── index_cache.zig            # IndexCache port (vtable)
├── app/
│   ├── update_index.zig           # use-case: refresh cached index
│   ├── get_info.zig               # use-case: one formula's metadata
│   ├── search.zig                 # use-case: substring match over index
│   └── resolve_deps.zig           # use-case: transitive deps for a formula
└── adapters/
    ├── http_client.zig            # std.http GET-to-string wrapper (verified spike code)
    ├── json_api_catalog.zig       # PackageCatalog over formulae.brew.sh JSON
    ├── fs_index_cache.zig         # IndexCache over std.fs at ~/.metalbrew/cache
    └── cli.zig                    # driving adapter: argv parse + dispatch + render
```

**Memory model:** each use-case is handed an `std.mem.Allocator`. Adapters allocate domain values into that allocator; the composition root uses an arena per command invocation and frees it on exit, so individual domain values need no per-field `deinit`.

---

## Task 1: Project scaffold and build

**Files:**
- Create: `build.zig`
- Create: `build.zig.zon`
- Create: `src/main.zig`
- Create: `src/root.zig`

- [ ] **Step 1: Create `build.zig.zon`**

```zig
.{
    .name = .metalbrew,
    .version = "0.0.0",
    .fingerprint = 0x9270341b1f654f61,
    .minimum_zig_version = "0.16.0",
    .dependencies = .{},
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
    },
}
```

- [ ] **Step 2: Create `build.zig`**

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("metalbrew", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "metalbrew",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "metalbrew", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run metalbrew");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
```

- [ ] **Step 3: Create `src/root.zig` (test aggregator)**

```zig
//! metalbrew library root. Re-exports the public surface and aggregates tests.
const std = @import("std");

pub const config = @import("config.zig");
pub const domain = struct {
    pub const version = @import("domain/version.zig");
    pub const formula = @import("domain/formula.zig");
    pub const platform = @import("domain/platform.zig");
    pub const resolver = @import("domain/resolver.zig");
};
pub const ports = struct {
    pub const catalog = @import("ports/catalog.zig");
    pub const index_cache = @import("ports/index_cache.zig");
};
pub const app = struct {
    pub const update_index = @import("app/update_index.zig");
    pub const get_info = @import("app/get_info.zig");
    pub const search = @import("app/search.zig");
    pub const resolve_deps = @import("app/resolve_deps.zig");
};
pub const adapters = struct {
    pub const http_client = @import("adapters/http_client.zig");
    pub const json_api_catalog = @import("adapters/json_api_catalog.zig");
    pub const fs_index_cache = @import("adapters/fs_index_cache.zig");
    pub const cli = @import("adapters/cli.zig");
};

test {
    std.testing.refAllDeclsRecursive(@This());
}
```

> NOTE: Steps that create files referenced above (e.g. `src/domain/version.zig`) come in later tasks. Until they exist, comment out the not-yet-created lines in `root.zig` to keep the build green, and uncomment each as its task lands. Add a `// TODO(M1): uncomment when Task N lands` marker on each commented line.

For Task 1 only, `root.zig` should reference **just** `config`-free content. Replace the body above with this minimal version for the first commit, then expand it as modules are added:

```zig
//! metalbrew library root.
const std = @import("std");
test {
    std.testing.refAllDeclsRecursive(@This());
}
```

- [ ] **Step 4: Create `src/main.zig` (placeholder composition root)**

```zig
const std = @import("std");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const stdout = std.fs.File.stdout();
    try stdout.writeAll("metalbrew 0.0.0\n");
}
```

- [ ] **Step 5: Verify build and tests pass**

Run: `zig build && zig build test`
Expected: builds with no errors; test step runs and passes (zero tests yet).

Run: `./zig-out/bin/metalbrew`
Expected output: `metalbrew 0.0.0`

- [ ] **Step 6: Commit**

```bash
git add build.zig build.zig.zon src/main.zig src/root.zig docs/
git commit -m "chore: scaffold metalbrew hexagonal project (Zig 0.16)"
```

---

## Task 2: Domain — Version value object

**Files:**
- Create: `src/domain/version.zig`
- Modify: `src/root.zig` (uncomment `domain.version`)

- [ ] **Step 1: Write the failing test**

Append to `src/domain/version.zig`:

```zig
const std = @import("std");

/// A package version, e.g. "1.21.4" or "3.0.1_2" (homebrew revision suffix).
/// Stored as the original string plus a parsed list of numeric segments for ordering.
pub const Version = struct {
    raw: []const u8,

    pub fn init(raw: []const u8) Version {
        return .{ .raw = raw };
    }

    /// Order by dotted/underscored numeric segments, segment by segment.
    /// Missing segments compare as 0 (so "1.2" < "1.2.1").
    pub fn order(a: Version, b: Version) std.math.Order {
        var it_a = segmentIterator(a.raw);
        var it_b = segmentIterator(b.raw);
        while (true) {
            const sa = it_a.next();
            const sb = it_b.next();
            if (sa == null and sb == null) return .eq;
            const va = sa orelse 0;
            const vb = sb orelse 0;
            if (va < vb) return .lt;
            if (va > vb) return .gt;
        }
    }
};

const SegmentIterator = struct {
    rest: []const u8,
    fn next(self: *SegmentIterator) ?u64 {
        // skip separators
        while (self.rest.len > 0 and !std.ascii.isDigit(self.rest[0])) {
            self.rest = self.rest[1..];
        }
        if (self.rest.len == 0) return null;
        var i: usize = 0;
        while (i < self.rest.len and std.ascii.isDigit(self.rest[i])) : (i += 1) {}
        const num = std.fmt.parseInt(u64, self.rest[0..i], 10) catch 0;
        self.rest = self.rest[i..];
        return num;
    }
};

fn segmentIterator(raw: []const u8) SegmentIterator {
    return .{ .rest = raw };
}

test "order: equal versions" {
    try std.testing.expectEqual(std.math.Order.eq, Version.init("1.2.3").order(Version.init("1.2.3")));
}

test "order: patch difference" {
    try std.testing.expectEqual(std.math.Order.lt, Version.init("1.2.3").order(Version.init("1.2.4")));
    try std.testing.expectEqual(std.math.Order.gt, Version.init("1.3.0").order(Version.init("1.2.9")));
}

test "order: differing segment counts" {
    try std.testing.expectEqual(std.math.Order.lt, Version.init("1.2").order(Version.init("1.2.1")));
    try std.testing.expectEqual(std.math.Order.eq, Version.init("1.2.0").order(Version.init("1.2")));
}

test "order: homebrew revision suffix" {
    try std.testing.expectEqual(std.math.Order.lt, Version.init("3.0.1").order(Version.init("3.0.1_2")));
}
```

- [ ] **Step 2: Run test to verify it passes** (implementation is co-located above)

Run: `zig build test`
Expected: PASS, 4 version tests run.

> This task writes test+impl together because the VO is tiny and the test drives the public shape. If you prefer strict red/green, paste only the `test` blocks first, run (expect compile error "Version not defined"), then add the struct.

- [ ] **Step 3: Wire into `root.zig`**

In `src/root.zig`, ensure the aggregator references the domain. Replace the minimal body with:

```zig
//! metalbrew library root.
const std = @import("std");
pub const domain = struct {
    pub const version = @import("domain/version.zig");
};
test {
    std.testing.refAllDeclsRecursive(@This());
}
```

- [ ] **Step 4: Run tests**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/domain/version.zig src/root.zig
git commit -m "feat(domain): Version value object with segment ordering"
```

---

## Task 3: Domain — Formula, Dependency, BottleSpec value objects

**Files:**
- Create: `src/domain/formula.zig`
- Modify: `src/root.zig`

- [ ] **Step 1: Write the value objects with tests**

Create `src/domain/formula.zig`:

```zig
const std = @import("std");
const Version = @import("version.zig").Version;

/// A declared dependency on another formula. M1 only models the name and whether
/// it is a build-only dependency (which we exclude from runtime resolution).
pub const Dependency = struct {
    name: []const u8,
    build_only: bool = false,
};

/// Where a prebuilt bottle for one platform tag lives, plus its integrity hash.
pub const BottleSpec = struct {
    tag: []const u8, // e.g. "arm64_tahoe"
    url: []const u8,
    sha256: []const u8,
};

/// The domain aggregate: everything metalbrew knows about one package.
/// All slices are borrowed from the allocator that built the Formula.
pub const Formula = struct {
    name: []const u8,
    version: Version,
    desc: []const u8 = "",
    homepage: []const u8 = "",
    dependencies: []const Dependency = &.{},
    bottles: []const BottleSpec = &.{},

    /// Find the bottle matching a platform tag, if any.
    pub fn bottleFor(self: Formula, tag: []const u8) ?BottleSpec {
        for (self.bottles) |b| {
            if (std.mem.eql(u8, b.tag, tag)) return b;
        }
        return null;
    }

    /// Runtime dependency names only (build-only deps excluded).
    /// Writes into `out` (must have capacity >= dependencies.len); returns the used slice.
    pub fn runtimeDeps(self: Formula, out: [][]const u8) [][]const u8 {
        var n: usize = 0;
        for (self.dependencies) |d| {
            if (d.build_only) continue;
            out[n] = d.name;
            n += 1;
        }
        return out[0..n];
    }
};

test "bottleFor returns matching tag" {
    const f = Formula{
        .name = "wget",
        .version = Version.init("1.21.4"),
        .bottles = &.{
            .{ .tag = "arm64_sonoma", .url = "u1", .sha256 = "h1" },
            .{ .tag = "arm64_tahoe", .url = "u2", .sha256 = "h2" },
        },
    };
    const b = f.bottleFor("arm64_tahoe").?;
    try std.testing.expectEqualStrings("u2", b.url);
    try std.testing.expect(f.bottleFor("x86_64_linux") == null);
}

test "runtimeDeps excludes build-only" {
    const f = Formula{
        .name = "wget",
        .version = Version.init("1.21.4"),
        .dependencies = &.{
            .{ .name = "pkg-config", .build_only = true },
            .{ .name = "libidn2" },
            .{ .name = "openssl@3" },
        },
    };
    var buf: [8][]const u8 = undefined;
    const rt = f.runtimeDeps(&buf);
    try std.testing.expectEqual(@as(usize, 2), rt.len);
    try std.testing.expectEqualStrings("libidn2", rt[0]);
    try std.testing.expectEqualStrings("openssl@3", rt[1]);
}
```

- [ ] **Step 2: Run tests**

Run: `zig build test`
Expected: PASS, 2 new tests.

- [ ] **Step 3: Wire into `root.zig`** — add `pub const formula = @import("domain/formula.zig");` inside `domain`.

- [ ] **Step 4: Run tests** — `zig build test` → PASS.

- [ ] **Step 5: Commit**

```bash
git add src/domain/formula.zig src/root.zig
git commit -m "feat(domain): Formula/Dependency/BottleSpec value objects"
```

---

## Task 4: Domain — dependency resolver (domain service)

**Files:**
- Create: `src/domain/resolver.zig`
- Modify: `src/root.zig`

This is the heart of the domain: given a way to look up a formula by name (a pure function pointer, NOT a port — the domain stays I/O-free), compute the transitive runtime dependency closure in install order (dependencies before dependents).

- [ ] **Step 1: Write the failing test**

Create `src/domain/resolver.zig`:

```zig
const std = @import("std");
const Formula = @import("formula.zig").Formula;

/// Pure lookup function: name -> Formula (or null if unknown).
/// The domain depends on this function shape, not on any adapter.
pub const Lookup = *const fn (ctx: *const anyopaque, name: []const u8) ?Formula;

pub const ResolveError = error{ UnknownFormula, CycleDetected, OutOfMemory };

/// Returns the transitive runtime dependency closure of `root`, in topological
/// order (each formula appears after all of its dependencies). The root itself
/// is the last element. Caller owns the returned slice (allocated with `allocator`).
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

const TestGraph = struct {
    map: std.StringHashMapUnmanaged(Formula),

    fn lookupFn(ctx: *const anyopaque, name: []const u8) ?Formula {
        const self: *const TestGraph = @ptrCast(@alignCast(ctx));
        return self.map.get(name);
    }
};

fn mkFormula(name: []const u8, deps: []const []const u8, buf: []@import("formula.zig").Dependency) Formula {
    const Dependency = @import("formula.zig").Dependency;
    for (deps, 0..) |d, i| buf[i] = Dependency{ .name = d };
    _ = Dependency;
    return .{ .name = name, .version = Version.init("1.0"), .dependencies = buf[0..deps.len] };
}

test "resolve: linear chain a->b->c yields c,b,a" {
    const a = std.testing.allocator;
    var g = TestGraph{ .map = .empty };
    defer g.map.deinit(a);
    var db: [1]@import("formula.zig").Dependency = undefined;
    var bb: [1]@import("formula.zig").Dependency = undefined;
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
    var top: [2]@import("formula.zig").Dependency = undefined;
    var lb: [1]@import("formula.zig").Dependency = undefined;
    var rb: [1]@import("formula.zig").Dependency = undefined;
    try g.map.put(a, "top", mkFormula("top", &.{ "left", "right" }, &top));
    try g.map.put(a, "left", mkFormula("left", &.{"base"}, &lb));
    try g.map.put(a, "right", mkFormula("right", &.{"base"}, &rb));
    try g.map.put(a, "base", mkFormula("base", &.{}, &.{}));

    const order = try resolve(a, &g, TestGraph.lookupFn, "top");
    defer a.free(order);
    try std.testing.expectEqual(@as(usize, 4), order.len); // base appears once
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
    var ab: [1]@import("formula.zig").Dependency = undefined;
    var bb: [1]@import("formula.zig").Dependency = undefined;
    try g.map.put(a, "a", mkFormula("a", &.{"b"}, &ab));
    try g.map.put(a, "b", mkFormula("b", &.{"a"}, &bb));
    try std.testing.expectError(error.CycleDetected, resolve(a, &g, TestGraph.lookupFn, "a"));
}
```

- [ ] **Step 2: Run tests**

Run: `zig build test`
Expected: PASS, 4 resolver tests. If `ArrayList`/`StringHashMapUnmanaged` `.empty` or `append(allocator, ...)` signatures error, that is the 0.16 unmanaged-collections API — confirm with `grep -n "pub const empty" /opt/homebrew/Cellar/zig/0.16.0/lib/zig/std/array_list.zig` and adjust the call to match (in 0.16 the unmanaged containers take the allocator per-call).

- [ ] **Step 3: Wire into `root.zig`** — add `pub const resolver = @import("domain/resolver.zig");`.

- [ ] **Step 4: Run tests** — `zig build test` → PASS.

- [ ] **Step 5: Commit**

```bash
git add src/domain/resolver.zig src/root.zig
git commit -m "feat(domain): transitive dependency resolver with cycle detection"
```

---

## Task 5: Ports — PackageCatalog and IndexCache (with FakeCatalog test double)

**Files:**
- Create: `src/ports/catalog.zig`
- Create: `src/ports/index_cache.zig`
- Modify: `src/root.zig`

Ports are vtable structs so the app can hold a `PackageCatalog` without knowing whether it is the JSON adapter or a fake.

- [ ] **Step 1: Define `PackageCatalog` port + `FakeCatalog` double with a test**

Create `src/ports/catalog.zig`:

```zig
const std = @import("std");
const Formula = @import("../domain/formula.zig").Formula;

/// Driven port: the application's view of "where formula metadata comes from".
/// Implemented by adapters/json_api_catalog.zig in production and FakeCatalog in tests.
pub const PackageCatalog = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Look up one formula by name. Allocates returned data with `allocator`.
        get: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!?Formula,
        /// Return all known formula names. Allocates with `allocator`.
        names: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![][]const u8,
    };

    pub fn get(self: PackageCatalog, allocator: std.mem.Allocator, name: []const u8) anyerror!?Formula {
        return self.vtable.get(self.ptr, allocator, name);
    }
    pub fn names(self: PackageCatalog, allocator: std.mem.Allocator) anyerror![][]const u8 {
        return self.vtable.names(self.ptr, allocator);
    }
};

/// In-memory test double. Backed by a caller-populated map of name -> Formula.
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
```

- [ ] **Step 2: Define `IndexCache` port**

Create `src/ports/index_cache.zig`:

```zig
const std = @import("std");

/// Driven port: persistence of the raw downloaded index document.
/// Production adapter is adapters/fs_index_cache.zig.
pub const IndexCache = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Read the cached index bytes, or null if absent. Allocates with `allocator`.
        read: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!?[]u8,
        /// Overwrite the cached index with `bytes`.
        write: *const fn (ptr: *anyopaque, bytes: []const u8) anyerror!void,
    };

    pub fn read(self: IndexCache, allocator: std.mem.Allocator) anyerror!?[]u8 {
        return self.vtable.read(self.ptr, allocator);
    }
    pub fn write(self: IndexCache, bytes: []const u8) anyerror!void {
        return self.vtable.write(self.ptr, bytes);
    }
};
```

- [ ] **Step 3: Run tests** — `zig build test` → PASS (1 new test). Wire both into `root.zig` under a `ports` struct.

- [ ] **Step 4: Commit**

```bash
git add src/ports/catalog.zig src/ports/index_cache.zig src/root.zig
git commit -m "feat(ports): PackageCatalog + IndexCache ports with FakeCatalog double"
```

---

## Task 6: Adapter — HTTP client wrapper

**Files:**
- Create: `src/adapters/http_client.zig`
- Modify: `src/root.zig`

Thin wrapper over the verified `std.http` pattern. Returns the body as an owned slice.

- [ ] **Step 1: Write the wrapper**

Create `src/adapters/http_client.zig`:

```zig
const std = @import("std");

/// Owns an Io + std.http.Client for the process lifetime. Construct once in main.
pub const HttpClient = struct {
    threaded: std.Io.Threaded,
    client: std.http.Client,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) HttpClient {
        var self: HttpClient = undefined;
        self.allocator = allocator;
        self.threaded = .init(allocator, .{});
        self.client = .{ .allocator = allocator, .io = self.threaded.io() };
        return self;
    }

    pub fn deinit(self: *HttpClient) void {
        self.client.deinit();
        self.threaded.deinit();
    }

    pub const GetError = error{ HttpStatus, OutOfMemory } || anyerror;

    /// GET `url`, returning the response body as a slice owned by `allocator`.
    /// Errors with error.HttpStatus on any non-200 response.
    pub fn getAlloc(self: *HttpClient, allocator: std.mem.Allocator, url: []const u8) GetError![]u8 {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        const res = try self.client.fetch(.{
            .location = .{ .url = url },
            .response_writer = &aw.writer,
        });
        if (@intFromEnum(res.status) != 200) {
            aw.deinit();
            return error.HttpStatus;
        }
        return aw.toOwnedSlice();
    }
};
```

> NOTE on the self-referential init: `self.client.io` points at `self.threaded`'s vtable, which is fine because `Threaded.io()` returns a vtable + pointer to the Threaded value, and `HttpClient` is returned by value then stored at a stable address by the caller (composition root keeps it on the stack/heap for the whole run). If miscompilation appears, switch to heap allocation: `init` returns `*HttpClient`.

- [ ] **Step 2: Add a network integration test (opt-in)**

Append to `src/adapters/http_client.zig`:

```zig
test "getAlloc fetches the brew API (network)" {
    if (std.process.hasEnvVarConstant("METALBREW_SKIP_NET")) return error.SkipZigTest;
    const a = std.testing.allocator;
    var http = HttpClient.init(a);
    defer http.deinit();
    const body = http.getAlloc(a, "https://formulae.brew.sh/api/formula/wget.json") catch |e| {
        std.debug.print("network test skipped: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    defer a.free(body);
    try std.testing.expect(body.len > 100);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\"") != null);
}
```

- [ ] **Step 3: Run tests**

Run: `zig build test`
Expected: PASS (network test fetches real data, as proven by the spike). To run offline: `METALBREW_SKIP_NET=1 zig build test` → the test self-skips.

- [ ] **Step 4: Wire into `root.zig`, commit**

```bash
git add src/adapters/http_client.zig src/root.zig
git commit -m "feat(adapter): std.http GET-to-string client wrapper"
```

---

## Task 7: Adapter — JsonApiCatalog (JSON → Formula)

**Files:**
- Create: `src/adapters/json_api_catalog.zig`
- Create: `src/testdata/wget.json` (fixture)
- Modify: `src/root.zig`

The adapter implements `PackageCatalog` by parsing the brew JSON. The **parsing** is tested with an embedded fixture (pure, no network); the **fetching** reuses the Task 6 client.

- [ ] **Step 1: Capture a real fixture**

Run:
```bash
mkdir -p src/testdata
curl -s https://formulae.brew.sh/api/formula/wget.json -o src/testdata/wget.json
test -s src/testdata/wget.json && echo OK
```
Expected: `OK` and a JSON file (~5 KB).

- [ ] **Step 2: Write the failing parse test**

Create `src/adapters/json_api_catalog.zig`:

```zig
const std = @import("std");
const Formula = @import("../domain/formula.zig").Formula;
const Dependency = @import("../domain/formula.zig").Dependency;
const BottleSpec = @import("../domain/formula.zig").BottleSpec;
const Version = @import("../domain/version.zig").Version;

/// Parse one formula object (the shape returned by /api/formula/<name>.json) into
/// a domain Formula. All slices are allocated with `allocator`.
pub fn parseFormula(allocator: std.mem.Allocator, json_bytes: []const u8) !Formula {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();
    return try formulaFromValue(allocator, parsed.value);
}

fn formulaFromValue(allocator: std.mem.Allocator, value: std.json.Value) !Formula {
    const obj = value.object;
    const name = try allocator.dupe(u8, obj.get("name").?.string);

    // versions.stable
    const versions = obj.get("versions").?.object;
    const ver_raw = try allocator.dupe(u8, versions.get("stable").?.string);

    const desc = if (obj.get("desc")) |d| switch (d) {
        .string => |s| try allocator.dupe(u8, s),
        else => "",
    } else "";

    // dependencies (runtime) + build_dependencies
    var deps: std.ArrayList(Dependency) = .empty;
    if (obj.get("dependencies")) |d| {
        for (d.array.items) |item| {
            try deps.append(allocator, .{ .name = try allocator.dupe(u8, item.string) });
        }
    }
    if (obj.get("build_dependencies")) |d| {
        for (d.array.items) |item| {
            try deps.append(allocator, .{ .name = try allocator.dupe(u8, item.string), .build_only = true });
        }
    }

    // bottles: bottle.stable.files.<tag> = { url, sha256 }
    var bottles: std.ArrayList(BottleSpec) = .empty;
    if (obj.get("bottle")) |b| {
        if (b.object.get("stable")) |stable| {
            if (stable.object.get("files")) |files| {
                var it = files.object.iterator();
                while (it.next()) |entry| {
                    const f = entry.value_ptr.*.object;
                    try bottles.append(allocator, .{
                        .tag = try allocator.dupe(u8, entry.key_ptr.*),
                        .url = try allocator.dupe(u8, f.get("url").?.string),
                        .sha256 = try allocator.dupe(u8, f.get("sha256").?.string),
                    });
                }
            }
        }
    }

    return .{
        .name = name,
        .version = Version.init(ver_raw),
        .desc = desc,
        .dependencies = try deps.toOwnedSlice(allocator),
        .bottles = try bottles.toOwnedSlice(allocator),
    };
}

test "parseFormula extracts wget from fixture" {
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bytes = @embedFile("../testdata/wget.json");
    const f = try parseFormula(arena, bytes);
    try std.testing.expectEqualStrings("wget", f.name);
    try std.testing.expect(f.dependencies.len >= 1);
    // wget depends on libidn2 (verified live)
    var found = false;
    for (f.dependencies) |d| {
        if (std.mem.eql(u8, d.name, "libidn2")) found = true;
    }
    try std.testing.expect(found);
}
```

> The fixture for /api/formula/<name>.json is a single object. The full index /api/formula.json is an array of these objects — handled in Task 8's cache parse by iterating `parsed.value.array.items` through `formulaFromValue`.

- [ ] **Step 3: Run the test**

Run: `zig build test`
Expected: PASS. If the brew schema differs from assumptions (e.g. `versions.stable` missing), adjust field access to match the actual fixture — open `src/testdata/wget.json` and confirm key paths.

- [ ] **Step 4: Add the catalog port implementation over HttpClient**

Append to `src/adapters/json_api_catalog.zig`:

```zig
const PackageCatalog = @import("../ports/catalog.zig").PackageCatalog;
const HttpClient = @import("http_client.zig").HttpClient;

/// Production PackageCatalog: fetches single formulae on demand from the API.
/// (The cached full-index variant is wired in Task 8 + Task 9.)
pub const JsonApiCatalog = struct {
    http: *HttpClient,
    base_url: []const u8 = "https://formulae.brew.sh/api/formula",

    pub fn port(self: *JsonApiCatalog) PackageCatalog {
        return .{ .ptr = self, .vtable = &vtable };
    }
    const vtable = PackageCatalog.VTable{ .get = getImpl, .names = namesImpl };

    fn getImpl(ptr: *anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!?Formula {
        const self: *JsonApiCatalog = @ptrCast(@alignCast(ptr));
        const url = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ self.base_url, name });
        defer allocator.free(url);
        const body = self.http.getAlloc(allocator, url) catch |e| switch (e) {
            error.HttpStatus => return null, // 404 -> unknown formula
            else => return e,
        };
        defer allocator.free(body);
        return try parseFormula(allocator, body);
    }
    fn namesImpl(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![][]const u8 {
        _ = ptr;
        _ = allocator;
        return error.Unsupported; // per-formula adapter can't list; use the cached index (Task 9)
    }
};
```

- [ ] **Step 5: Run tests, wire into `root.zig`, commit**

Run: `zig build test` → PASS.

```bash
git add src/adapters/json_api_catalog.zig src/testdata/wget.json src/root.zig
git commit -m "feat(adapter): JsonApiCatalog parses brew JSON into domain Formula"
```

---

## Task 8: Adapter — FsIndexCache

**Files:**
- Create: `src/adapters/fs_index_cache.zig`
- Modify: `src/root.zig`

- [ ] **Step 1: Write the failing test (round-trips through a temp dir)**

Create `src/adapters/fs_index_cache.zig`:

```zig
const std = @import("std");
const IndexCache = @import("../ports/index_cache.zig").IndexCache;

/// IndexCache backed by a file at `<cache_dir>/formula.json`.
pub const FsIndexCache = struct {
    cache_dir: []const u8,
    file_name: []const u8 = "formula.json",

    pub fn port(self: *FsIndexCache) IndexCache {
        return .{ .ptr = self, .vtable = &vtable };
    }
    const vtable = IndexCache.VTable{ .read = readImpl, .write = writeImpl };

    fn pathAlloc(self: *FsIndexCache, allocator: std.mem.Allocator) ![]u8 {
        return std.fs.path.join(allocator, &.{ self.cache_dir, self.file_name });
    }

    fn readImpl(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!?[]u8 {
        const self: *FsIndexCache = @ptrCast(@alignCast(ptr));
        const path = try self.pathAlloc(allocator);
        defer allocator.free(path);
        const file = std.fs.cwd().openFile(path, .{}) catch |e| switch (e) {
            error.FileNotFound => return null,
            else => return e,
        };
        defer file.close();
        return try file.readToEndAlloc(allocator, 64 * 1024 * 1024); // 64 MB cap for full index
    }

    fn writeImpl(ptr: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *FsIndexCache = @ptrCast(@alignCast(ptr));
        std.fs.cwd().makePath(self.cache_dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ self.cache_dir, self.file_name });
        const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(bytes);
    }
};

test "FsIndexCache write then read round-trips" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir_path);

    var cache = FsIndexCache{ .cache_dir = dir_path };
    const port = cache.port();

    try std.testing.expect((try port.read(a)) == null); // nothing cached yet
    try port.write("[{\"name\":\"wget\"}]");
    const got = (try port.read(a)).?;
    defer a.free(got);
    try std.testing.expectEqualStrings("[{\"name\":\"wget\"}]", got);
}
```

- [ ] **Step 2: Run test** — `zig build test` → PASS. If `tmpDir`/`realpathAlloc`/`readToEndAlloc` signatures differ in 0.16, confirm via `grep -n "pub fn readToEndAlloc\|pub fn tmpDir" /opt/homebrew/Cellar/zig/0.16.0/lib/zig/std/fs*.zig /opt/homebrew/Cellar/zig/0.16.0/lib/zig/std/testing.zig` and adjust.

- [ ] **Step 3: Wire into `root.zig`, commit**

```bash
git add src/adapters/fs_index_cache.zig src/root.zig
git commit -m "feat(adapter): FsIndexCache file-backed index persistence"
```

---

## Task 9: App — use-cases over the ports

**Files:**
- Create: `src/app/update_index.zig`
- Create: `src/app/get_info.zig`
- Create: `src/app/search.zig`
- Create: `src/app/resolve_deps.zig`
- Create: `src/adapters/cached_catalog.zig` (a `PackageCatalog` over a parsed cached index — needed for search/info/deps offline)
- Modify: `src/root.zig`

These are tested with `FakeCatalog` / in-memory `IndexCache`, never touching the network.

- [ ] **Step 1: `CachedIndexCatalog` — PackageCatalog backed by the cached full index**

Create `src/adapters/cached_catalog.zig`:

```zig
const std = @import("std");
const Formula = @import("../domain/formula.zig").Formula;
const PackageCatalog = @import("../ports/catalog.zig").PackageCatalog;
const json_api = @import("json_api_catalog.zig");

/// Parses the full index (array of formula objects) once, exposes it as a catalog.
pub const CachedIndexCatalog = struct {
    arena: std.heap.ArenaAllocator,
    by_name: std.StringHashMapUnmanaged(Formula) = .empty,

    /// Build from the raw full-index bytes (/api/formula.json, a JSON array).
    pub fn init(backing: std.mem.Allocator, index_bytes: []const u8) !CachedIndexCatalog {
        var self = CachedIndexCatalog{ .arena = std.heap.ArenaAllocator.init(backing) };
        const a = self.arena.allocator();
        const parsed = try std.json.parseFromSlice(std.json.Value, a, index_bytes, .{});
        // parsed lives in arena; do not deinit separately
        for (parsed.value.array.items) |item| {
            const f = try json_api.formulaFromValuePub(a, item);
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
};
```

In `src/adapters/json_api_catalog.zig`, expose the helper used here by renaming `formulaFromValue` to `pub fn formulaFromValuePub` (or adding `pub const formulaFromValuePub = formulaFromValue;`). Add that line and re-run Task 7 tests to confirm green.

- [ ] **Step 2: `UpdateIndex` use-case + test**

Create `src/app/update_index.zig`:

```zig
const std = @import("std");
const HttpClient = @import("../adapters/http_client.zig").HttpClient;
const IndexCache = @import("../ports/index_cache.zig").IndexCache;

pub const INDEX_URL = "https://formulae.brew.sh/api/formula.json";

/// Fetch the full index and store it via the cache port. Returns byte count written.
pub fn run(allocator: std.mem.Allocator, http: *HttpClient, cache: IndexCache, url: []const u8) !usize {
    const body = try http.getAlloc(allocator, url);
    defer allocator.free(body);
    try cache.write(body);
    return body.len;
}
```

Test (uses an in-memory IndexCache double + skips if offline). Append:

```zig
const MemCache = struct {
    buf: ?[]u8 = null,
    a: std.mem.Allocator,
    fn port(self: *MemCache) IndexCache {
        return .{ .ptr = self, .vtable = &.{ .read = rd, .write = wr } };
    }
    fn rd(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!?[]u8 {
        const s: *MemCache = @ptrCast(@alignCast(ptr));
        if (s.buf) |b| return try allocator.dupe(u8, b);
        return null;
    }
    fn wr(ptr: *anyopaque, bytes: []const u8) anyerror!void {
        const s: *MemCache = @ptrCast(@alignCast(ptr));
        if (s.buf) |b| s.a.free(b);
        s.buf = try s.a.dupe(u8, bytes);
    }
};

test "UpdateIndex writes fetched bytes to cache (network)" {
    if (std.process.hasEnvVarConstant("METALBREW_SKIP_NET")) return error.SkipZigTest;
    const a = std.testing.allocator;
    var http = HttpClient.init(a);
    defer http.deinit();
    var mem = MemCache{ .a = a };
    defer if (mem.buf) |b| a.free(b);
    const n = run(a, &http, mem.port(), INDEX_URL) catch return error.SkipZigTest;
    try std.testing.expect(n > 1000);
    try std.testing.expect(mem.buf != null);
}
```

- [ ] **Step 3: `GetInfo`, `Search`, `ResolveDeps` use-cases + tests**

Create `src/app/get_info.zig`:

```zig
const std = @import("std");
const Formula = @import("../domain/formula.zig").Formula;
const PackageCatalog = @import("../ports/catalog.zig").PackageCatalog;

pub const Error = error{NotFound} || anyerror;

/// Look up one formula; error.NotFound if the catalog has no such name.
pub fn run(allocator: std.mem.Allocator, catalog: PackageCatalog, name: []const u8) Error!Formula {
    return (try catalog.get(allocator, name)) orelse error.NotFound;
}

const FakeCatalog = @import("../ports/catalog.zig").FakeCatalog;
const Version = @import("../domain/version.zig").Version;

test "GetInfo returns formula or NotFound" {
    const a = std.testing.allocator;
    var fake = FakeCatalog{};
    defer fake.map.deinit(a);
    try fake.map.put(a, "wget", .{ .name = "wget", .version = Version.init("1.21.4"), .desc = "Internet file retriever" });
    const f = try run(a, fake.port(), "wget");
    try std.testing.expectEqualStrings("Internet file retriever", f.desc);
    try std.testing.expectError(error.NotFound, run(a, fake.port(), "ghost"));
}
```

Create `src/app/search.zig`:

```zig
const std = @import("std");
const PackageCatalog = @import("../ports/catalog.zig").PackageCatalog;

/// Return names containing `query` (case-insensitive substring), sorted ascending.
/// Caller owns the slice and each element is borrowed from the catalog.
pub fn run(allocator: std.mem.Allocator, catalog: PackageCatalog, query: []const u8) ![][]const u8 {
    const all = try catalog.names(allocator);
    defer allocator.free(all);
    var hits: std.ArrayList([]const u8) = .empty;
    for (all) |name| {
        if (containsIgnoreCase(name, query)) try hits.append(allocator, name);
    }
    const out = try hits.toOwnedSlice(allocator);
    std.mem.sort([]const u8, out, {}, lessThan);
    return out;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

const FakeCatalog = @import("../ports/catalog.zig").FakeCatalog;
const Version = @import("../domain/version.zig").Version;

test "Search returns sorted case-insensitive substring matches" {
    const a = std.testing.allocator;
    var fake = FakeCatalog{};
    defer fake.map.deinit(a);
    try fake.map.put(a, "wget", .{ .name = "wget", .version = Version.init("1") });
    try fake.map.put(a, "widget", .{ .name = "widget", .version = Version.init("1") });
    try fake.map.put(a, "curl", .{ .name = "curl", .version = Version.init("1") });
    const hits = try run(a, fake.port(), "GET");
    defer a.free(hits);
    try std.testing.expectEqual(@as(usize, 2), hits.len);
    try std.testing.expectEqualStrings("wget", hits[0]);
    try std.testing.expectEqualStrings("widget", hits[1]);
}
```

Create `src/app/resolve_deps.zig` (bridges the catalog port into the pure domain resolver):

```zig
const std = @import("std");
const PackageCatalog = @import("../ports/catalog.zig").PackageCatalog;
const resolver = @import("../domain/resolver.zig");
const Formula = @import("../domain/formula.zig").Formula;

/// Resolve the transitive runtime dependency order for `name`.
/// Loads each needed formula through the catalog into `allocator`.
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
const Dependency = @import("../domain/formula.zig").Dependency;
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
```

- [ ] **Step 4: Run all tests** — `zig build test` → PASS. Wire each new module into `root.zig`.

- [ ] **Step 5: Commit**

```bash
git add src/app/ src/adapters/cached_catalog.zig src/adapters/json_api_catalog.zig src/root.zig
git commit -m "feat(app): UpdateIndex/GetInfo/Search/ResolveDeps use-cases over ports"
```

---

## Task 10: Config — prefix and cache path resolution

**Files:**
- Create: `src/config.zig`
- Modify: `src/root.zig`

- [ ] **Step 1: Write the failing test + impl**

Create `src/config.zig`:

```zig
const std = @import("std");

/// Resolved filesystem layout for a metalbrew installation.
pub const Paths = struct {
    prefix: []const u8, // ~/.metalbrew (or $METALBREW_PREFIX)
    cache_api: []const u8, // <prefix>/cache/api

    /// Resolve from environment. `METALBREW_PREFIX` overrides the default `$HOME/.metalbrew`.
    /// All returned strings are owned by `allocator`.
    pub fn resolve(allocator: std.mem.Allocator, env: *std.process.EnvMap) !Paths {
        const prefix = if (env.get("METALBREW_PREFIX")) |p|
            try allocator.dupe(u8, p)
        else blk: {
            const home = env.get("HOME") orelse return error.NoHome;
            break :blk try std.fs.path.join(allocator, &.{ home, ".metalbrew" });
        };
        const cache_api = try std.fs.path.join(allocator, &.{ prefix, "cache", "api" });
        return .{ .prefix = prefix, .cache_api = cache_api };
    }

    pub fn deinit(self: Paths, allocator: std.mem.Allocator) void {
        allocator.free(self.prefix);
        allocator.free(self.cache_api);
    }
};

test "resolve defaults to $HOME/.metalbrew" {
    const a = std.testing.allocator;
    var env = std.process.EnvMap.init(a);
    defer env.deinit();
    try env.put("HOME", "/Users/test");
    const paths = try Paths.resolve(a, &env);
    defer paths.deinit(a);
    try std.testing.expectEqualStrings("/Users/test/.metalbrew", paths.prefix);
    try std.testing.expectEqualStrings("/Users/test/.metalbrew/cache/api", paths.cache_api);
}

test "resolve honors METALBREW_PREFIX" {
    const a = std.testing.allocator;
    var env = std.process.EnvMap.init(a);
    defer env.deinit();
    try env.put("HOME", "/Users/test");
    try env.put("METALBREW_PREFIX", "/opt/mb");
    const paths = try Paths.resolve(a, &env);
    defer paths.deinit(a);
    try std.testing.expectEqualStrings("/opt/mb", paths.prefix);
    try std.testing.expectEqualStrings("/opt/mb/cache/api", paths.cache_api);
}
```

- [ ] **Step 2: Run tests** — `zig build test` → PASS. Wire `config` into `root.zig`.

- [ ] **Step 3: Commit**

```bash
git add src/config.zig src/root.zig
git commit -m "feat(config): prefix + cache path resolution"
```

---

## Task 11: Driving adapter — CLI + composition root

**Files:**
- Create: `src/adapters/cli.zig`
- Modify: `src/main.zig`
- Modify: `src/root.zig`

The CLI parses argv into a command, the composition root wires real adapters, and the CLI renders results. `update` uses `HttpClient`+`FsIndexCache`+`UpdateIndex`; `info`/`search`/`deps` read the cached index via `CachedIndexCatalog`.

- [ ] **Step 1: Parse command enum (testable, pure)**

Create `src/adapters/cli.zig`:

```zig
const std = @import("std");

pub const Command = union(enum) {
    help,
    update,
    info: []const u8,
    search: []const u8,
    deps: []const u8,
    unknown: []const u8,

    /// Parse argv[1..] into a Command. `args` excludes the program name.
    pub fn parse(args: []const []const u8) Command {
        if (args.len == 0) return .help;
        const cmd = args[0];
        if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) return .help;
        if (std.mem.eql(u8, cmd, "update")) return .update;
        if (std.mem.eql(u8, cmd, "info")) return if (args.len >= 2) .{ .info = args[1] } else .help;
        if (std.mem.eql(u8, cmd, "search")) return if (args.len >= 2) .{ .search = args[1] } else .help;
        if (std.mem.eql(u8, cmd, "deps")) return if (args.len >= 2) .{ .deps = args[1] } else .help;
        return .{ .unknown = cmd };
    }
};

test "parse maps verbs to commands" {
    try std.testing.expect(Command.parse(&.{}) == .help);
    try std.testing.expect(Command.parse(&.{"update"}) == .update);
    try std.testing.expectEqualStrings("wget", Command.parse(&.{ "info", "wget" }).info);
    try std.testing.expectEqualStrings("ssl", Command.parse(&.{ "search", "ssl" }).search);
    try std.testing.expectEqualStrings("wget", Command.parse(&.{ "deps", "wget" }).deps);
    try std.testing.expectEqualStrings("frobnicate", Command.parse(&.{"frobnicate"}).unknown);
    try std.testing.expect(Command.parse(&.{"info"}) == .help); // missing arg
}
```

- [ ] **Step 2: Run test** — `zig build test` → PASS. Wire `cli` into `root.zig`.

- [ ] **Step 3: Implement the composition root in `main.zig`**

Replace `src/main.zig` with:

```zig
const std = @import("std");
const mb = @import("metalbrew");
const Command = mb.adapters.cli.Command;
const HttpClient = mb.adapters.http_client.HttpClient;
const FsIndexCache = mb.adapters.fs_index_cache.FsIndexCache;
const CachedIndexCatalog = @import("adapters/cached_catalog.zig").CachedIndexCatalog;
const Paths = mb.config.Paths;
const update_index = mb.app.update_index;
const get_info = mb.app.get_info;
const search = mb.app.search;
const resolve_deps = mb.app.resolve_deps;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const base = gpa.allocator();

    var arena_state = std.heap.ArenaAllocator.init(base);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var env = try std.process.getEnvMap(a);
    const paths = try Paths.resolve(a, &env);

    const argv = try std.process.argsAlloc(a);
    const cmd = Command.parse(argv[@min(1, argv.len)..]);

    var out_buf: [4096]u8 = undefined;
    var out = std.fs.File.stdout().writer(&out_buf);
    const w = &out.interface;
    defer w.flush() catch {};

    switch (cmd) {
        .help, .unknown => try printHelp(w),
        .update => {
            var http = HttpClient.init(base);
            defer http.deinit();
            var cache = FsIndexCache{ .cache_dir = paths.cache_api };
            const n = try update_index.run(a, &http, cache.port(), update_index.INDEX_URL);
            try w.print("Updated index: {d} bytes -> {s}/formula.json\n", .{ n, paths.cache_api });
        },
        .info => |name| {
            var catalog = try loadCachedCatalog(base, a, paths);
            defer catalog.deinit();
            const f = get_info.run(a, catalog.port(), name) catch |e| switch (e) {
                error.NotFound => {
                    try w.print("No formula named '{s}'. Try `metalbrew update` first.\n", .{name});
                    return;
                },
                else => return e,
            };
            try w.print("{s}: {s}\n{s}\n", .{ f.name, f.version.raw, f.desc });
            if (f.dependencies.len > 0) {
                try w.writeAll("Dependencies: ");
                for (f.dependencies, 0..) |d, i| {
                    if (i > 0) try w.writeAll(", ");
                    try w.writeAll(d.name);
                }
                try w.writeAll("\n");
            }
        },
        .search => |q| {
            var catalog = try loadCachedCatalog(base, a, paths);
            defer catalog.deinit();
            const hits = try search.run(a, catalog.port(), q);
            for (hits) |name| try w.print("{s}\n", .{name});
        },
        .deps => |name| {
            var catalog = try loadCachedCatalog(base, a, paths);
            defer catalog.deinit();
            const order = try resolve_deps.run(a, catalog.port(), name);
            // print deps only (exclude the root itself, which is last)
            const deps = if (order.len > 0) order[0 .. order.len - 1] else order;
            for (deps) |d| try w.print("{s}\n", .{d});
        },
    }
}

fn loadCachedCatalog(base: std.mem.Allocator, a: std.mem.Allocator, paths: Paths) !CachedIndexCatalog {
    var cache = FsIndexCache{ .cache_dir = paths.cache_api };
    const bytes = (try cache.port().read(a)) orelse {
        return error.NoIndex; // surfaced to user as "run update first" by caller if desired
    };
    return CachedIndexCatalog.init(base, bytes);
}

fn printHelp(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\metalbrew — read-only spine (M1)
        \\
        \\Usage:
        \\  metalbrew update            Refresh the formula index
        \\  metalbrew info <formula>    Show formula metadata
        \\  metalbrew search <query>    Search formula names
        \\  metalbrew deps <formula>    Show transitive runtime dependencies
        \\
    );
}
```

> NOTE: confirm the 0.16 stdout writer API via `grep -n "pub fn stdout\|pub fn writer" /opt/homebrew/Cellar/zig/0.16.0/lib/zig/std/fs/File.zig`. The `std.fs.File.stdout().writer(&buf).interface` pattern is the 0.16 idiom; if it differs, mirror what `zig init`'s template `main.zig` does (captured earlier: it uses `std.Io.Writer` via `File.stdout()`).

- [ ] **Step 4: Build and smoke-test end to end**

Run:
```bash
zig build
./zig-out/bin/metalbrew help
METALBREW_PREFIX="$(mktemp -d)/mb" ./zig-out/bin/metalbrew update
```
Expected: help text prints; `update` downloads the full index and reports a byte count (the spike proved connectivity). Then:
```bash
PREFIX=$(mktemp -d)/mb
METALBREW_PREFIX="$PREFIX" ./zig-out/bin/metalbrew update
METALBREW_PREFIX="$PREFIX" ./zig-out/bin/metalbrew info wget
METALBREW_PREFIX="$PREFIX" ./zig-out/bin/metalbrew search wget
METALBREW_PREFIX="$PREFIX" ./zig-out/bin/metalbrew deps wget
```
Expected: `info wget` prints name/version/desc + deps; `deps wget` lists `libidn2` etc.; `search wget` lists `wget` (and `wget2` if present).

- [ ] **Step 5: Run the full test suite**

Run: `zig build test`
Expected: ALL tests PASS. Offline: `METALBREW_SKIP_NET=1 zig build test`.

- [ ] **Step 6: Commit**

```bash
git add src/adapters/cli.zig src/main.zig src/root.zig
git commit -m "feat(cli): wire composition root for update/info/search/deps"
```

---

## Self-Review

**Spec coverage (M1 = read-only spine: update/info/search/deps + transitive resolution over JSON index, hexagonal + DDD):**
- `update` → Task 9 (`UpdateIndex`) + Task 11 wiring. ✅
- `info` → Task 9 (`GetInfo`) + Task 11. ✅
- `search` → Task 9 (`Search`) + Task 11. ✅
- `deps` (transitive) → Task 4 (domain resolver) + Task 9 (`ResolveDeps`) + Task 11. ✅
- JSON index fetch/parse/cache → Tasks 6, 7, 8, 9. ✅
- Hexagonal: domain (T2–T4) has zero I/O imports; ports (T5); app depends on ports (T9); adapters implement ports (T6–T9); composition root (T11). ✅
- DDD value objects: `Version`, `Formula`, `Dependency`, `BottleSpec` (T2–T3); domain service `resolver` (T4). ✅
- Prefix `~/.metalbrew`, no sudo → Task 10. ✅
- `Tag`/`platform.zig` value object: listed in file structure but only consumed by M2 (bottle selection). **Deferred to M2** — `BottleSpec.tag` is a plain string in M1, which is sufficient for `info`/`deps`. Noted, not silently dropped.

**Placeholder scan:** no "TBD"/"add error handling"/"similar to Task N". Each code step has complete code. The only forward-references (`root.zig` uncommenting) are explicitly sequenced with the NOTE in Task 1.

**Type consistency:** `PackageCatalog.get` returns `anyerror!?Formula` everywhere (ports T5, adapters T7/T9, app T9). `IndexCache.read` returns `anyerror!?[]u8` (T5, T8, T9). `resolver.resolve(allocator, ctx, lookup, root)` signature matches its caller in `resolve_deps.run` (T4 ↔ T9). `Formula.runtimeDeps(out)` buffer-based API consistent (T3 ↔ T4). `Version.init`/`Version.order` consistent (T2 ↔ T3/T9).

**Known risk flagged for the executor:** Zig 0.16's unmanaged-collection (`ArrayList`/`StringHashMapUnmanaged` `.empty` + per-call allocator) and `std.Io.Writer`/`std.fs.File` APIs are new. Each task that uses them includes a `grep` fallback to confirm the exact signature against the installed stdlib before adjusting. The HTTP + JSON core is already spike-verified.

---

## Next milestones (separate plans)
- **M2 — Install pipeline:** ghcr.io Bearer-token fetch + sha256 verify → pour → Mach-O relocation (+ `codesign --sign - --force`) → keg linking → `INSTALL_RECEIPT.json`. Commands: `install`, `list`, `uninstall`. Adds a `BottleFetcher` port + `Relocator` + `Linker` domain/adapters and a `platform.Tag` detector adapter.
- **M3 — Upgrade:** version-diff cached index vs installed receipts, reinstall newer. Command: `upgrade`.
