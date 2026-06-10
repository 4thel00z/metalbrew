# metalbrew M2 — Install Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install real Homebrew bottles into metalbrew's own prefix: fetch from ghcr.io, verify sha256, pour into the Cellar, relocate baked paths, link into the prefix, and record receipts — wired through `install`, `list`, `uninstall` (with transitive dependency installs).

**Architecture:** Extends M1's hexagonal layering. New driven ports (`BottleFetcher`, `ReceiptStore`) and adapters (ghcr fetcher, pour, relocator, linker, fs receipts). The install use-case composes M1's `ResolveDeps` (transitive order) with the new fetch→verify→pour→relocate→link→receipt pipeline per keg. The relocator and pour are adapters (they do I/O and shell out); the domain gains only small value objects (`Tag`, `Keg`).

**Tech Stack:** Zig 0.16.0, `std.http` with `extra_headers` (Bearer auth), `std.crypto.hash.sha2.Sha256`, `std.compress.flate` (gzip) + `std.tar`, `std.process.Child` (shelling out to `install_name_tool` + `codesign`). Target: macOS arm64, prefix `~/.metalbrew`.

---

## Verified mechanisms (spike-proven on this machine — do not re-derive)

- **Bottle URL** comes from the formula JSON: `bottle.stable.files.<tag>.{url,sha256}`, e.g. `https://ghcr.io/v2/homebrew/core/xz/blobs/sha256:<digest>`.
- **ghcr download requires `Authorization: Bearer QQ==`** (Homebrew's anonymous token). Spike: `curl -L -H "Authorization: Bearer QQ==" <url>` → HTTP 200, bytes whose sha256 **exactly matches** the manifest digest, a gzip tarball.
- **Bottle tarball layout** is already keg-shaped: top-level `<name>/<version>/…` (e.g. `xz/5.8.3/bin/xz`, `xz/5.8.3/lib/liblzma.5.dylib`, `xz/5.8.3/.brew/xz.rb`). Extracting into `<prefix>/Cellar/` yields `<prefix>/Cellar/xz/5.8.3/…`.
- **Relocation is placeholder-based, NOT literal `/opt/homebrew`** (grepping the xz bottle for `/opt/homebrew` found nothing). Baked strings use `@@HOMEBREW_PREFIX@@` and `@@HOMEBREW_CELLAR@@`:
  - Mach-O dylib id (otool -D): `@@HOMEBREW_PREFIX@@/opt/xz/lib/liblzma.5.dylib`
  - Mach-O load dep (otool -L): `@@HOMEBREW_CELLAR@@/xz/5.8.3/lib/liblzma.5.dylib`
  - Also in text files: `lib/pkgconfig/liblzma.pc`.
- **Relocation strategy** (the keystone, two cases by file type):
  1. **Mach-O files** (magic `0xFEEDFACF` LE 64-bit, or `0xCAFEBABE`/`0xCAFEBABF` fat): rewrite via **`install_name_tool`** (`-id`, `-change old new`, `-rpath old new`) — it relayouts load commands so the longer real path fits — then **`codesign --sign - --force <file>`** (editing invalidates the signature; arm64 requires valid/ad-hoc signature to run). Read current names with `otool -D` / `otool -L` / `otool -l` (or parse the header) to discover which load strings contain placeholders.
  2. **Non-Mach-O files**: byte-substitute `@@HOMEBREW_PREFIX@@`→`<prefix>` and `@@HOMEBREW_CELLAR@@`→`<prefix>/Cellar` (length-flexible; rewrite file). **Never** byte-substitute inside a Mach-O (changes length → corruption); always route Mach-O through `install_name_tool`.
- **`<prefix>` is the absolute resolved metalbrew prefix** (e.g. `/Users/you/.metalbrew`), `<cellar>` = `<prefix>/Cellar`.

### 0.16 stdlib APIs to confirm against `/opt/homebrew/Cellar/zig/0.16.0/lib/zig/std` (carry forward M1's lessons)
- All filesystem ops are on `std.Io.Dir`/`std.Io.File` and take `io: std.Io` (no `std.fs.cwd`/`std.fs.File`). Args/env/io/allocators come from `init: std.process.Init`.
- Test aggregation: NO `refAllDeclsRecursive`; add `_ = @import("…");` per new file to `src/root.zig`'s `test {}` block and confirm the count rises.
- `std.ArrayList(T)` unmanaged (`.empty`, `append(allocator,…)`, `toOwnedSlice(allocator)`).
- HTTP custom headers: `std.http.Client.fetch` accepts `extra_headers: []const std.http.Header` (a `Header` is `.{ .name, .value }`). Verify field names.
- gzip: `std.compress.flate` (gzip container) — verify the exact decompress entry (`std.compress.flate.Decompress` or a gzip helper). tar: `std.tar` (`pipeToFileSystem` or the `Iterator`). Subprocess: `std.process.Child` — `wait(child, io)`/`kill(child, io)` take `io`; verify `Child.run`/`spawn`/`init` shape. **Treat plan code as intent; verify each call.**

## File structure (M2 additions)

```
src/
├── domain/
│   ├── platform.zig        # Tag value object + macOS-version→tag mapping (pure)
│   └── keg.zig             # Keg value object (name, version, paths) (pure)
├── ports/
│   ├── bottle_fetcher.zig  # BottleFetcher port (fetch+verify bottle bytes)
│   └── receipt_store.zig   # ReceiptStore port (record/list/remove installed kegs)
├── adapters/
│   ├── ghcr_fetcher.zig    # BottleFetcher over HttpClient (Bearer QQ==) + sha256 verify
│   ├── pour.zig            # gzip+tar extraction into the Cellar
│   ├── relocator.zig       # Mach-O (install_name_tool+codesign) + text placeholder sub
│   ├── linker.zig          # symlink keg into <prefix>/{bin,lib,include,share,…}
│   └── fs_receipts.zig     # ReceiptStore over <prefix>/<name>/INSTALL_RECEIPT-style state
├── app/
│   ├── install.zig         # transitive install: resolve → per keg fetch→pour→relocate→link→receipt
│   ├── uninstall.zig       # unlink + remove keg + receipt
│   └── list.zig            # list installed kegs from receipts
└── adapters/http_client.zig  # MODIFIED: add getAllocHeaders(...) with extra_headers
```

Plus platform tag detection (reads OS version) — an adapter helper in `platform.zig`'s composition usage or a tiny `os_tag.zig` adapter.

---

## Task 1: Extend HttpClient with custom headers

**Files:** Modify `src/adapters/http_client.zig`; modify `src/root.zig` (no new import).

- [ ] **Step 1: Add a header-bearing GET, keeping `getAlloc` as a thin caller**

Add to `HttpClient`:
```zig
/// GET `url` sending `headers` (e.g. Authorization). Body owned by `allocator`. Non-200 → error.HttpStatus.
pub fn getAllocHeaders(self: *HttpClient, allocator: std.mem.Allocator, url: []const u8, headers: []const std.http.Header) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const res = try self.client.fetch(.{
        .location = .{ .url = url },
        .extra_headers = headers,
        .response_writer = &aw.writer,
    });
    if (@intFromEnum(res.status) != 200) { aw.deinit(); return error.HttpStatus; }
    return aw.toOwnedSlice();
}
```
And make the existing `getAlloc` delegate: `return self.getAllocHeaders(allocator, url, &.{});`
Verify `std.http.Header` field names (`.name`/`.value`) against the stdlib.

- [ ] **Step 2: Test** — extend the existing opt-in network test (or add one) that fetches the xz bottle blob with `&.{.{ .name = "authorization", .value = "Bearer QQ==" }}` and asserts the body is non-empty and begins with the gzip magic `0x1f 0x8b`. Gate with `METALBREW_SKIP_NET`.

Run: `zig build test --summary all` (network on → passes; `METALBREW_SKIP_NET=1` → skips).

- [ ] **Step 3: Commit** — `git add -A && git commit -m "feat(adapter): HttpClient custom-header GET for ghcr auth"`

---

## Task 2: Domain — Tag value object + macOS tag mapping

**Files:** Create `src/domain/platform.zig`; modify `src/root.zig`.

- [ ] **Step 1: Pure Tag + version→codename mapping (TDD)**
```zig
const std = @import("std");

/// A bottle platform tag, e.g. "arm64_tahoe". Pure value object.
pub const Tag = struct {
    text: []const u8,
    pub fn eql(a: Tag, b: Tag) bool { return std.mem.eql(u8, a.text, b.text); }
};

/// Map a macOS major version to its arm64 bottle codename tag.
/// 26→tahoe, 15→sequoia, 14→sonoma, 13→ventura, 12→monterey.
pub fn arm64TagForMacOS(major: u32) ?Tag {
    const name: ?[]const u8 = switch (major) {
        26 => "tahoe", 15 => "sequoia", 14 => "sonoma", 13 => "ventura", 12 => "monterey",
        else => null,
    };
    return if (name) |n| .{ .text = "arm64_" ++ @as([]const u8, n) } else null;
}

/// Ordered fallback list (current first), so install can pick the best available bottle.
pub fn arm64FallbackTags(major: u32) []const []const u8 {
    return switch (major) {
        26 => &.{ "arm64_tahoe", "arm64_sequoia", "arm64_sonoma" },
        15 => &.{ "arm64_sequoia", "arm64_sonoma", "arm64_ventura" },
        14 => &.{ "arm64_sonoma", "arm64_ventura", "arm64_monterey" },
        else => &.{},
    };
}

test "arm64 tag mapping" {
    try std.testing.expectEqualStrings("arm64_tahoe", arm64TagForMacOS(26).?.text);
    try std.testing.expectEqualStrings("arm64_sequoia", arm64TagForMacOS(15).?.text);
    try std.testing.expect(arm64TagForMacOS(99) == null);
}
test "fallback list current-first" {
    const fb = arm64FallbackTags(26);
    try std.testing.expectEqualStrings("arm64_tahoe", fb[0]);
}
```
(The `"arm64_" ++ n` concat needs comptime-known `n`; the switch yields comptime string literals so it works. If the compiler rejects the runtime concat, build the string with `std.fmt.allocPrint` in a small helper taking an allocator, and adjust the test — but prefer the comptime form.)

- [ ] **Step 2: run tests** (+2), wire root.zig, **commit** `feat(domain): platform Tag + macOS bottle-tag mapping`.

---

## Task 3: Adapter — detect the host macOS tag

**Files:** Create `src/adapters/os_tag.zig`; modify `src/root.zig`.

- [ ] **Step 1: Detect the running macOS major version → Tag**

Read the OS version. Options to verify against 0.16: `std.zig.system` / `std.posix.uname` / reading via `std.c`. Simplest robust approach on macOS: run `sw_vers -productVersion` via `std.process.Child` and parse the major before the first `.`. Implement `detectArm64Tag(io, allocator) !platform.Tag` returning the current tag (e.g. `arm64_tahoe` on macOS 26). Since this is I/O, it's an adapter.
```zig
const std = @import("std");
const platform = @import("../domain/platform.zig");

/// Detect host macOS major version and map to the arm64 bottle tag.
pub fn detectArm64Tag(io: std.Io, allocator: std.mem.Allocator) !platform.Tag {
    const major = try macosMajor(io, allocator);
    return platform.arm64TagForMacOS(major) orelse error.UnsupportedMacOS;
}

fn macosMajor(io: std.Io, allocator: std.mem.Allocator) !u32 {
    // Run `sw_vers -productVersion`, capture stdout, parse leading integer.
    // Verify std.process.Child run/capture API on 0.16 (Child.run returns stdout/stderr + term).
    ...
}
```
- [ ] **Step 2:** Test `macosMajor`/`detectArm64Tag` by running it on this host and asserting it returns a non-error tag starting with `arm64_` (this host is macOS 26 → `arm64_tahoe`). Mark it network-free but host-dependent (it runs `sw_vers`). **commit** `feat(adapter): detect host macOS bottle tag`.

---

## Task 4: Ports — BottleFetcher and ReceiptStore

**Files:** Create `src/ports/bottle_fetcher.zig`, `src/ports/receipt_store.zig`; modify `src/root.zig`.

- [ ] **Step 1: Define the ports (vtable shape like M1's ports)**
```zig
// bottle_fetcher.zig
pub const BottleFetcher = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        /// Download the bottle at `url`, verify it matches `sha256_hex`, return bytes owned by allocator.
        fetch: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, url: []const u8, sha256_hex: []const u8) anyerror![]u8,
    };
    pub fn fetch(self: BottleFetcher, allocator, url, sha256_hex) anyerror![]u8 { return self.vtable.fetch(self.ptr, allocator, url, sha256_hex); }
};
```
```zig
// receipt_store.zig — records which kegs are installed (name -> version + linked files)
pub const Receipt = struct { name: []const u8, version: []const u8 };
pub const ReceiptStore = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        put: *const fn (ptr: *anyopaque, r: Receipt) anyerror!void,
        get: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!?Receipt,
        list: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]Receipt,
        remove: *const fn (ptr: *anyopaque, name: []const u8) anyerror!void,
    };
    // thin forwarding methods …
};
```
- [ ] **Step 2:** No behavior yet beyond shape; add a tiny fake for ReceiptStore used in later tests if convenient. Wire root.zig. **commit** `feat(ports): BottleFetcher + ReceiptStore ports`.

---

## Task 5: Adapter — ghcr BottleFetcher with sha256 verify

**Files:** Create `src/adapters/ghcr_fetcher.zig`; modify `src/root.zig`.

- [ ] **Step 1: Implement fetch + verify**
```zig
const std = @import("std");
const BottleFetcher = @import("../ports/bottle_fetcher.zig").BottleFetcher;
const HttpClient = @import("http_client.zig").HttpClient;

pub const GhcrFetcher = struct {
    http: *HttpClient,
    pub fn port(self: *GhcrFetcher) BottleFetcher { return .{ .ptr = self, .vtable = &vtable }; }
    const vtable = BottleFetcher.VTable{ .fetch = fetchImpl };

    fn fetchImpl(ptr: *anyopaque, allocator: std.mem.Allocator, url: []const u8, sha256_hex: []const u8) anyerror![]u8 {
        const self: *GhcrFetcher = @ptrCast(@alignCast(ptr));
        const headers = [_]std.http.Header{.{ .name = "authorization", .value = "Bearer QQ==" }};
        const body = try self.http.getAllocHeaders(allocator, url, &headers);
        errdefer allocator.free(body);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(body, &digest, .{});
        var hex: [64]u8 = undefined;
        _ = std.fmt.bufPrint(&hex, "{x}", .{std.fmt.fmtSliceHexLower(&digest)}) catch unreachable; // verify 0.16 hex-fmt API
        if (!std.mem.eql(u8, &hex, sha256_hex)) return error.ChecksumMismatch;
        return body;
    }
};
```
Verify the 0.16 hex-formatting API (`std.fmt.fmtSliceHexLower` may differ; alternatively format each byte). The checksum check is the security gate — get it right.

- [ ] **Step 2: Test (network, opt-in)** — fetch a known small bottle (e.g. xz) using the url+sha from the live API or a hardcoded known-good pair, assert success; then corrupt the expected sha and assert `error.ChecksumMismatch`. Gate network with `METALBREW_SKIP_NET`.
- [ ] **Step 3: commit** `feat(adapter): ghcr bottle fetcher with sha256 verification`.

---

## Task 6: Adapter — pour (gzip + tar extraction)

**Files:** Create `src/adapters/pour.zig`; modify `src/root.zig`.

- [ ] **Step 1: Extract a gzip tarball into a destination dir**
```zig
/// Decompress gzip `bottle_bytes` and untar into `dest_dir` (the Cellar).
/// The tarball is already keg-shaped (<name>/<version>/…), so dest_dir is <prefix>/Cellar.
pub fn pour(io: std.Io, dest_dir: std.Io.Dir, bottle_bytes: []const u8) !void { ... }
```
Verify the 0.16 gzip + tar API: likely `std.compress.flate.Decompress` (gzip container) feeding `std.tar.pipeToFileSystem(dest_dir, reader, .{ .mode_mode = .ignore, .strip_components = 0 })` — confirm the real function/options names. Reading from an in-memory slice uses a fixed reader; verify the 0.16 reader/`std.Io.Reader` plumbing.

- [ ] **Step 2: Test** — pour a tiny gzip tarball built in-test (or a committed small fixture `src/testdata/mini-bottle.tar.gz` containing `pkg/1.0/bin/hello`) into a `tmpDir`, then assert `pkg/1.0/bin/hello` exists with expected contents. No network.
- [ ] **Step 3: commit** `feat(adapter): pour gzip+tar bottle into Cellar`.

---

## Task 7: Adapter — relocator (the keystone)

**Files:** Create `src/adapters/relocator.zig`; modify `src/root.zig`.

- [ ] **Step 1: Classify files and relocate a keg directory**
```zig
/// Relocate all placeholder paths under `keg_dir` to the real prefix/cellar.
/// - Mach-O files: rewrite id/deps/rpaths via install_name_tool, then ad-hoc codesign.
/// - Other files containing a placeholder: byte-substitute and rewrite.
pub fn relocate(io: std.Io, allocator: std.mem.Allocator, keg_dir: std.Io.Dir, prefix: []const u8, cellar: []const u8) !void { ... }
```
Implementation outline (verify each 0.16 call):
1. Walk `keg_dir` recursively (`std.Io.Dir` walker — verify API).
2. For each regular file, read its first 4 bytes; if Mach-O magic (`0xFEEDFACF` little-endian for 64-bit; also handle `0xCAFEBABE`/`BF` fat), treat as Mach-O.
3. **Mach-O:** run `otool -D <f>` (id) and `otool -L <f>` (deps) and `otool -l` for `LC_RPATH`; for any string containing `@@HOMEBREW_PREFIX@@`/`@@HOMEBREW_CELLAR@@`, compute the replacement (prefix/cellar) and build an `install_name_tool` invocation: `-id <new>` if the id had a placeholder, `-change <old> <new>` per dep, `-rpath <old> <new>` per rpath. Run it via `std.process.Child`. Then `codesign --sign - --force <f>`.
4. **Non-Mach-O:** read file; if it contains a placeholder, `std.mem.replace` both placeholders → write back. (Skip if absent — avoid rewriting every file.)

Helper: `fn replacePlaceholders(allocator, input, prefix, cellar) ![]u8` (pure, TDD-able).

- [ ] **Step 2: Tests**
  - Pure unit test for `replacePlaceholders`: `"@@HOMEBREW_PREFIX@@/opt/xz/lib"` + prefix `/Users/x/.metalbrew` → `/Users/x/.metalbrew/opt/xz/lib`; same for `@@HOMEBREW_CELLAR@@`.
  - Integration (host-dependent, uses real tools): pour the real xz bottle into a tmp Cellar, run `relocate`, then assert (a) no file under the keg still contains `@@HOMEBREW`, and (b) `otool -L <keg>/bin/xz` shows the real prefix path and `codesign -v <keg>/bin/xz` succeeds. Skip gracefully if `install_name_tool`/`codesign` are absent.
- [ ] **Step 3: commit** `feat(adapter): bottle relocator (install_name_tool + codesign + text sub)`.

> This is the riskiest task. If install_name_tool/otool parsing proves too large for one task, split: 7a `replacePlaceholders` + text-file relocation; 7b Mach-O relocation. Report DONE_WITH_CONCERNS rather than guessing on Mach-O byte details — the install_name_tool approach avoids hand-parsing Mach-O.

---

## Task 8: Adapter — linker

**Files:** Create `src/adapters/linker.zig`; modify `src/root.zig`.

- [ ] **Step 1: Symlink a keg into the prefix**
```zig
/// Symlink the contents of <cellar>/<name>/<version> into <prefix> (bin, lib, include, share, etc.),
/// mirroring Homebrew's keg linking. Also create <prefix>/opt/<name> -> the keg.
pub fn link(io: std.Io, prefix_dir: std.Io.Dir, keg_rel_path: []const u8, name: []const u8) !void { ... }
/// Remove all symlinks pointing into the keg (for uninstall).
pub fn unlink(io: std.Io, prefix_dir: std.Io.Dir, name: []const u8) !void { ... }
```
For M2, link top-level standard subdirs (bin, lib, include, share, etc, sbin, lib/pkgconfig) by symlinking each file. Keep it simple: walk the keg, for each file under a linkable subdir create a relative symlink at `<prefix>/<subdir>/<...>`. Verify the 0.16 symlink API on `std.Io.Dir` (`symLink`/`symlink`). Create `<prefix>/opt/<name>` → keg.

- [ ] **Step 2: Test** — in a tmp prefix, create a fake keg `Cellar/pkg/1.0/bin/hello`, run `link`, assert `<prefix>/bin/hello` resolves to the keg file; run `unlink`, assert it's gone. No network.
- [ ] **Step 3: commit** `feat(adapter): keg linker/unlinker`.

---

## Task 9: Adapter — fs ReceiptStore

**Files:** Create `src/adapters/fs_receipts.zig`; modify `src/root.zig`.

- [ ] **Step 1: Persist receipts** — store one JSON file per installed keg at `<prefix>/var/metalbrew/receipts/<name>.json` containing `{ "name", "version" }`. Implement `put`/`get`/`list`/`remove` over `std.Io.Dir`. `list` enumerates the receipts dir.
- [ ] **Step 2: Test** — tmp prefix round-trip: put two receipts, list → 2, get one, remove one, list → 1. No network.
- [ ] **Step 3: commit** `feat(adapter): filesystem receipt store`.

---

## Task 10: App — install use-case

**Files:** Create `src/app/install.zig`; modify `src/root.zig`.

- [ ] **Step 1: Compose the pipeline** — `run` takes the catalog (for formula metadata), resolve_deps (transitive order), the chosen `Tag`, fetcher, prefix/cellar dirs, relocator, linker, receipts. For each formula in dependency order (deps first): skip if a receipt already exists; else look up the formula, pick the bottle for the tag (with fallback list), fetch+verify, pour into the Cellar, relocate the new keg, link it, write a receipt. Return the list of newly installed kegs.
```zig
pub fn run(ctx: InstallCtx, root_name: []const u8) ![]const []const u8 { ... }
```
where `InstallCtx` bundles the ports/dirs/tag (a struct) to keep the signature sane.

- [ ] **Step 2: Test** — pure-ish test with fakes: a `FakeCatalog` with `a`→`b` deps, a fake `BottleFetcher` returning a tiny in-memory gzip tarball for each, a tmp prefix. Assert both kegs poured + linked + receipted in order (b before a). Relocation can be a no-op for the synthetic fixture (no placeholders). No network.
- [ ] **Step 3: commit** `feat(app): transitive install use-case`.

---

## Task 11: App — list + uninstall use-cases

**Files:** Create `src/app/list.zig`, `src/app/uninstall.zig`; modify `src/root.zig`.

- [ ] **Step 1: list** — return receipts (name+version), sorted. **uninstall** — unlink, remove keg dir from Cellar, remove receipt; error if not installed.
- [ ] **Step 2: Tests** with fakes/tmp prefix: install two (via Task 10 or by seeding receipts+kegs), list → 2 sorted; uninstall one → list → 1 and its links gone; uninstall missing → error.
- [ ] **Step 3: commit** `feat(app): list + uninstall use-cases`.

---

## Task 12: CLI + composition root wiring

**Files:** Modify `src/adapters/cli.zig`, `src/main.zig`, `src/root.zig`.

- [ ] **Step 1: Extend `Command`** with `install: []const u8`, `uninstall: []const u8`, `list`. Update `parse` + its unit test.
- [ ] **Step 2: Wire main** — for `install <name>`: build HttpClient, GhcrFetcher, detect tag, open/create Cellar + prefix dirs, construct relocator/linker/fs_receipts, run `install`, print each newly installed keg. For `list`: print installed kegs. For `uninstall <name>`: run uninstall with a friendly not-installed message. Reuse the M1 patterns (Init, stdout writer, dir creation). Update `printHelp`.
- [ ] **Step 3: END-TO-END smoke (the real guard):**
  ```bash
  zig build
  PREFIX="$(mktemp -d)/mb"
  METALBREW_PREFIX="$PREFIX" ./zig-out/bin/metalbrew update
  METALBREW_PREFIX="$PREFIX" ./zig-out/bin/metalbrew install xz   # fetch+verify+pour+relocate+link+receipt
  "$PREFIX/bin/xz" --version                                      # the linked, relocated binary must RUN
  METALBREW_PREFIX="$PREFIX" ./zig-out/bin/metalbrew list          # shows xz + its deps
  METALBREW_PREFIX="$PREFIX" ./zig-out/bin/metalbrew uninstall xz  # unlinks + removes
  ```
  `"$PREFIX/bin/xz" --version` actually running is the definitive proof relocation+codesign worked. Capture all output.
- [ ] **Step 4: commit** `feat(cli): wire install/list/uninstall`.

---

## Self-Review

**Spec coverage (M2 = install/list/uninstall + transitive installs over ghcr bottles, relocated into own prefix):**
- ghcr fetch + Bearer auth → Tasks 1, 5. sha256 verify → Task 5. ✅
- Pour (gzip+tar) → Task 6. ✅
- Relocation (Mach-O via install_name_tool+codesign; text placeholder sub) → Task 7. ✅
- Keg linking → Task 8. Receipts → Task 9. ✅
- Transitive `install` → Task 10 (composes M1 ResolveDeps). `list`/`uninstall` → Task 11. CLI → Task 12. ✅
- Platform tag selection (arm64_tahoe + fallback) → Tasks 2, 3. ✅

**Placeholder scan:** Code-bearing steps give concrete code; the genuinely uncertain 0.16 calls (gzip/tar/Child/symlink/hex-fmt) are flagged with explicit "verify against stdlib" notes rather than fake APIs — consistent with how M1 succeeded. No "TBD"/"add error handling".

**Type consistency:** `BottleFetcher.fetch(allocator,url,sha256_hex)` consistent across port (T4), adapter (T5), and install (T10). `ReceiptStore` put/get/list/remove consistent (T4/T9/T11). `Tag.text` used in platform (T2), os_tag (T3), install (T10).

**Known risk:** Task 7 (relocation) is the hard frontier. The install_name_tool+codesign approach (vs hand-parsing Mach-O) is what makes it tractable, and the `"$PREFIX/bin/xz" --version` e2e check in Task 12 is the end-to-end proof. If Task 7 must be split, do 7a (text) then 7b (Mach-O).

---

## Next milestone (separate plan)
- **M3 — Upgrade:** diff installed receipts vs the cached index, reinstall newer bottles. Command: `upgrade`. Builds directly on M2's install pipeline.
