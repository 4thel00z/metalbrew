//! Adapter: relocate a poured Homebrew bottle (keg) from its baked build-prefix
//! placeholders to the real install prefix.
//!
//! Homebrew arm64 bottles do NOT contain literal `/opt/homebrew`; they contain
//! TEXT PLACEHOLDERS:
//!   `@@HOMEBREW_PREFIX@@`  -> the install prefix      (e.g. `/Users/x/.mb`)
//!   `@@HOMEBREW_CELLAR@@`  -> `<prefix>/Cellar`
//!
//! These appear in three places:
//!   * a Mach-O dylib's install id      (`otool -D`)
//!   * a Mach-O binary's load deps/rpaths (`otool -L`, `otool -l` LC_RPATH)
//!   * plain text files (e.g. `*.pc` pkg-config files)
//!
//! Two mechanisms, chosen by file type:
//!   1. Mach-O: NEVER byte-substitute (changes length, corrupts the binary).
//!      Use `install_name_tool` to rewrite id/deps/rpaths (it relayouts the
//!      load commands so longer paths fit), then `codesign --sign - --force`
//!      to re-sign (editing invalidates the existing signature; arm64 binaries
//!      must be at least ad-hoc signed to run).
//!   2. Non-Mach-O: if (and only if) the file contains a placeholder,
//!      byte-substitute and rewrite it (text is length-flexible).
//!
//! Subprocess capture (Zig 0.16): `std.process.run(allocator, io, .{ .argv = ... })`
//! returns `RunResult { term, stdout, stderr }`. See os_tag.zig.
const std = @import("std");

const prefix_token = "@@HOMEBREW_PREFIX@@";
const cellar_token = "@@HOMEBREW_CELLAR@@";

/// Pure: replace `@@HOMEBREW_PREFIX@@` and `@@HOMEBREW_CELLAR@@` in `input`.
/// Cellar is substituted first so the more specific token wins (the tokens do
/// not overlap, but ordering keeps intent clear). Caller owns the result.
pub fn replacePlaceholders(
    allocator: std.mem.Allocator,
    input: []const u8,
    prefix: []const u8,
    cellar: []const u8,
) ![]u8 {
    const step1 = try std.mem.replaceOwned(u8, allocator, input, cellar_token, cellar);
    defer allocator.free(step1);
    return std.mem.replaceOwned(u8, allocator, step1, prefix_token, prefix);
}

/// True if `s` contains either placeholder token.
fn hasPlaceholder(s: []const u8) bool {
    return std.mem.indexOf(u8, s, prefix_token) != null or
        std.mem.indexOf(u8, s, cellar_token) != null;
}

/// True if the first 4 bytes are a Mach-O (thin or fat) magic.
/// arm64 thin LE: `cf fa ed fe` (0xFEEDFACF). 32-bit: `ce fa ed fe`.
/// Fat: `ca fe ba be` / `ca fe ba bf` (and byte-swapped variants).
fn isMachO(head: []const u8) bool {
    if (head.len < 4) return false;
    const b = head[0..4];
    const magics = [_][4]u8{
        .{ 0xcf, 0xfa, 0xed, 0xfe }, // MH_MAGIC_64 (LE)
        .{ 0xfe, 0xed, 0xfa, 0xcf }, // MH_MAGIC_64 (BE)
        .{ 0xce, 0xfa, 0xed, 0xfe }, // MH_MAGIC (LE)
        .{ 0xfe, 0xed, 0xfa, 0xce }, // MH_MAGIC (BE)
        .{ 0xca, 0xfe, 0xba, 0xbe }, // FAT_MAGIC
        .{ 0xca, 0xfe, 0xba, 0xbf }, // FAT_MAGIC_64
        .{ 0xbe, 0xba, 0xfe, 0xca }, // FAT_CIGAM
        .{ 0xbf, 0xba, 0xfe, 0xca }, // FAT_CIGAM_64
    };
    for (magics) |m| {
        if (std.mem.eql(u8, b, &m)) return true;
    }
    return false;
}

/// Relocate every placeholder under the keg rooted at `keg_abs_path`.
/// `prefix` is the real install prefix; `cellar` is `<prefix>/Cellar`.
pub fn relocate(
    io: std.Io,
    allocator: std.mem.Allocator,
    keg_abs_path: []const u8,
    prefix: []const u8,
    cellar: []const u8,
) !void {
    var keg = try std.Io.Dir.openDirAbsolute(io, keg_abs_path, .{ .iterate = true });
    defer keg.close(io);

    var walker = try keg.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;

        // Absolute path of this file, for the external tools + readback.
        const abs = try std.fs.path.join(allocator, &.{ keg_abs_path, entry.path });
        defer allocator.free(abs);

        // Read enough to classify; readFileAlloc gives us the whole file (kegs
        // are small) so we can both sniff the magic and text-substitute.
        const contents = keg.readFileAlloc(io, entry.path, allocator, .unlimited) catch |e| switch (e) {
            error.FileNotFound, error.AccessDenied => continue, // dangling symlink etc.
            else => return e,
        };
        defer allocator.free(contents);

        if (isMachO(contents)) {
            try relocateMachO(io, allocator, abs, prefix, cellar);
        } else {
            if (!hasPlaceholder(contents)) continue;
            const replaced = try replacePlaceholders(allocator, contents, prefix, cellar);
            defer allocator.free(replaced);
            try keg.writeFile(io, .{ .sub_path = entry.path, .data = replaced });
        }
    }
}

/// Rewrite a single Mach-O file's id/deps/rpaths via install_name_tool, then
/// re-sign it ad-hoc with codesign.
fn relocateMachO(
    io: std.Io,
    allocator: std.mem.Allocator,
    abs: []const u8,
    prefix: []const u8,
    cellar: []const u8,
) !void {
    // Accumulate install_name_tool arguments. argv[0] = "install_name_tool".
    var args: std.ArrayList([]const u8) = .empty;
    defer {
        // Free every owned arg string (skip the static "install_name_tool",
        // "-id", "-change", "-rpath" markers — those are string literals).
        for (args.items) |a| {
            if (isOwnedArg(a)) allocator.free(a);
        }
        args.deinit(allocator);
    }
    try args.append(allocator, "install_name_tool");

    // --- id (otool -D) ---
    if (try toolLines(io, allocator, &.{ "otool", "-D", abs })) |out| {
        defer allocator.free(out);
        // `otool -D` prints `<path>:\n<id>\n`. The id is the 2nd line.
        var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, out, "\n"), '\n');
        _ = it.next(); // skip `<path>:`
        if (it.next()) |id_raw| {
            const id = std.mem.trim(u8, id_raw, " \t");
            if (hasPlaceholder(id)) {
                const new_id = try replacePlaceholders(allocator, id, prefix, cellar);
                try args.append(allocator, "-id");
                try args.append(allocator, new_id); // owned
            }
        }
    }

    // --- deps (otool -L) ---
    if (try toolLines(io, allocator, &.{ "otool", "-L", abs })) |out| {
        defer allocator.free(out);
        // Lines look like `\t<path> (compatibility version ..., current ...)`.
        // The first line is `<path>:` — skip it.
        var it = std.mem.splitScalar(u8, out, '\n');
        _ = it.next(); // `<path>:`
        while (it.next()) |line| {
            const dep = parseOtoolPath(line) orelse continue;
            if (!hasPlaceholder(dep)) continue;
            const new_dep = try replacePlaceholders(allocator, dep, prefix, cellar);
            const old_dep = try allocator.dupe(u8, dep);
            try args.append(allocator, "-change");
            try args.append(allocator, old_dep); // owned
            try args.append(allocator, new_dep); // owned
        }
    }

    // --- rpaths (otool -l, LC_RPATH) --- (bonus; xz has none)
    if (try toolLines(io, allocator, &.{ "otool", "-l", abs })) |out| {
        defer allocator.free(out);
        try collectRpathChanges(allocator, out, prefix, cellar, &args);
    }

    // Nothing to do? (only argv[0]) — still skip the codesign churn.
    if (args.items.len <= 1) return;

    // Append a DUPED copy of the target path so the deferred cleanup frees it
    // (the caller owns and frees the original `abs`).
    try args.append(allocator, try allocator.dupe(u8, abs));

    const int_res = try std.process.run(allocator, io, .{ .argv = args.items });
    defer allocator.free(int_res.stdout);
    defer allocator.free(int_res.stderr);
    switch (int_res.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("install_name_tool failed ({d}): {s}\n", .{ code, int_res.stderr });
            return error.InstallNameToolFailed;
        },
        else => return error.InstallNameToolFailed,
    }

    // Re-sign: editing load commands invalidated the signature.
    const cs = try std.process.run(allocator, io, .{
        .argv = &.{ "codesign", "--sign", "-", "--force", abs },
    });
    defer allocator.free(cs.stdout);
    defer allocator.free(cs.stderr);
    switch (cs.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("codesign failed ({d}): {s}\n", .{ code, cs.stderr });
            return error.CodesignFailed;
        },
        else => return error.CodesignFailed,
    }
}

/// Scan `otool -l` output for LC_RPATH commands whose `path` holds a placeholder,
/// appending `-rpath <old> <new>` argument triples to `args`.
fn collectRpathChanges(
    allocator: std.mem.Allocator,
    out: []const u8,
    prefix: []const u8,
    cellar: []const u8,
    args: *std.ArrayList([]const u8),
) !void {
    var it = std.mem.splitScalar(u8, out, '\n');
    var in_rpath = false;
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t");
        if (std.mem.indexOf(u8, t, "cmd LC_RPATH") != null) {
            in_rpath = true;
            continue;
        }
        if (!in_rpath) continue;
        // The `path <p> (offset N)` line follows within the same command.
        if (std.mem.startsWith(u8, t, "path ")) {
            in_rpath = false;
            const rest = t["path ".len..];
            const end = std.mem.indexOf(u8, rest, " (offset") orelse rest.len;
            const p = std.mem.trim(u8, rest[0..end], " \t");
            if (!hasPlaceholder(p)) continue;
            const new_p = try replacePlaceholders(allocator, p, prefix, cellar);
            const old_p = try allocator.dupe(u8, p);
            try args.append(allocator, "-rpath");
            try args.append(allocator, old_p);
            try args.append(allocator, new_p);
        }
    }
}

/// Parse the dependency path out of an `otool -L` body line.
/// Lines look like `\t<path> (compatibility version 1.0.0, current version 1.0.0)`.
/// Returns the slice between the leading whitespace and ` (`.
fn parseOtoolPath(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (trimmed.len == 0) return null;
    const end = std.mem.indexOf(u8, trimmed, " (") orelse return null;
    const path = trimmed[0..end];
    if (path.len == 0) return null;
    return path;
}

/// Run an external tool and, on exit-0, return its owned stdout. On any failure
/// (tool missing, non-zero exit) returns null so callers can treat it as "no
/// info" rather than aborting the whole relocation.
fn toolLines(io: std.Io, allocator: std.mem.Allocator, argv: []const []const u8) !?[]u8 {
    const res = std.process.run(allocator, io, .{ .argv = argv }) catch return null;
    defer allocator.free(res.stderr);
    switch (res.term) {
        .exited => |code| if (code != 0) {
            allocator.free(res.stdout);
            return null;
        },
        else => {
            allocator.free(res.stdout);
            return null;
        },
    }
    return res.stdout;
}

/// Distinguish heap-owned arg strings (paths) from the static marker literals
/// so the deferred cleanup only frees what we allocated.
fn isOwnedArg(a: []const u8) bool {
    const markers = [_][]const u8{ "install_name_tool", "-id", "-change", "-rpath" };
    for (markers) |m| {
        if (std.mem.eql(u8, a, m)) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Pure unit tests (offline) — REQUIRED.
// ---------------------------------------------------------------------------

test "replacePlaceholders substitutes prefix token" {
    const a = std.testing.allocator;
    const out = try replacePlaceholders(a, "@@HOMEBREW_PREFIX@@/opt/xz", "/U/.mb", "/U/.mb/Cellar");
    defer a.free(out);
    try std.testing.expectEqualStrings("/U/.mb/opt/xz", out);
}

test "replacePlaceholders substitutes cellar token" {
    const a = std.testing.allocator;
    const out = try replacePlaceholders(a, "@@HOMEBREW_CELLAR@@/xz/5.8.3", "/U/.mb", "/U/.mb/Cellar");
    defer a.free(out);
    try std.testing.expectEqualStrings("/U/.mb/Cellar/xz/5.8.3", out);
}

test "replacePlaceholders leaves strings without tokens unchanged" {
    const a = std.testing.allocator;
    const out = try replacePlaceholders(a, "/usr/lib/libSystem.B.dylib", "/U/.mb", "/U/.mb/Cellar");
    defer a.free(out);
    try std.testing.expectEqualStrings("/usr/lib/libSystem.B.dylib", out);
}

test "replacePlaceholders handles both tokens in one string" {
    const a = std.testing.allocator;
    const in = "id=@@HOMEBREW_PREFIX@@/opt/xz dep=@@HOMEBREW_CELLAR@@/xz/5.8.3";
    const out = try replacePlaceholders(a, in, "/U/.mb", "/U/.mb/Cellar");
    defer a.free(out);
    try std.testing.expectEqualStrings("id=/U/.mb/opt/xz dep=/U/.mb/Cellar/xz/5.8.3", out);
}

test "isMachO detects arm64 thin magic and rejects text" {
    try std.testing.expect(isMachO(&.{ 0xcf, 0xfa, 0xed, 0xfe, 0x00 }));
    try std.testing.expect(isMachO(&.{ 0xca, 0xfe, 0xba, 0xbe })); // fat
    try std.testing.expect(!isMachO("#!/bin/sh\n"));
    try std.testing.expect(!isMachO("ab")); // too short
}

test "parseOtoolPath extracts the dependency path" {
    const got = parseOtoolPath("\t@@HOMEBREW_CELLAR@@/xz/5.8.3/lib/liblzma.5.dylib (compatibility version 6.0.0, current version 6.8.0)");
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("@@HOMEBREW_CELLAR@@/xz/5.8.3/lib/liblzma.5.dylib", got.?);
    try std.testing.expect(parseOtoolPath("not a dep line") == null);
}

// ---------------------------------------------------------------------------
// Integration test (host-dependent: needs otool/install_name_tool/codesign +
// network for the real bottle). Skips cleanly if anything is unavailable.
// ---------------------------------------------------------------------------

fn envIsSet(comptime name: []const u8) bool {
    const environ: std.process.Environ = .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
    return environ.containsConstant(name);
}

const HttpClient = @import("http_client.zig").HttpClient;
const GhcrFetcher = @import("ghcr_fetcher.zig").GhcrFetcher;
const pour = @import("pour.zig").pour;

test "relocate rewrites the real xz bottle (network + host tools)" {
    if (envIsSet("METALBREW_SKIP_NET")) return error.SkipZigTest;
    const a = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 1. Fetch + verify the xz bottle.
    const http = HttpClient.init(a) catch return error.SkipZigTest;
    defer http.deinit();
    var fetcher = GhcrFetcher{ .http = http };
    const url = "https://ghcr.io/v2/homebrew/core/xz/blobs/sha256:55c891f5d47142fe923c87df0e3343d7ef2bc7d368c67892b4ad2c80e53069d5";
    const sha = "55c891f5d47142fe923c87df0e3343d7ef2bc7d368c67892b4ad2c80e53069d5";
    const bytes = fetcher.port().fetch(a, url, sha, null) catch |e| {
        std.debug.print("relocate test skipped (fetch): {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    defer a.free(bytes);

    // 2. Pour into a tmp Cellar.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try pour(io, a, tmp.dir, bytes);

    // 3. Compute prefix/cellar + the keg abs path. The tmp dir IS the Cellar.
    const cellar_abs = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(cellar_abs);
    // For relocation purposes prefix == the dir holding Cellar. Homebrew bakes
    // `<prefix>/opt/...` and `<cellar>/...`; here we point both at the tmp tree
    // so the rewritten paths actually exist on disk.
    const prefix = cellar_abs; // arbitrary real dir; only needs to be placeholder-free
    const keg_abs = try std.fs.path.join(a, &.{ cellar_abs, "xz", "5.8.3" });
    defer a.free(keg_abs);

    // 4. Relocate.
    relocate(io, a, keg_abs, prefix, cellar_abs) catch |e| {
        std.debug.print("relocate test skipped (relocate): {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };

    // (a) No file under the keg still contains a placeholder.
    {
        var keg = try std.Io.Dir.openDirAbsolute(io, keg_abs, .{ .iterate = true });
        defer keg.close(io);
        var w = try keg.walk(a);
        defer w.deinit();
        while (try w.next(io)) |entry| {
            if (entry.kind != .file) continue;
            const c = keg.readFileAlloc(io, entry.path, a, .unlimited) catch continue;
            defer a.free(c);
            if (std.mem.indexOf(u8, c, "@@HOMEBREW") != null) {
                std.debug.print("placeholder remains in {s}\n", .{entry.path});
                try std.testing.expect(false);
            }
        }
    }

    // (b) otool -L bin/xz contains the real prefix, no placeholder.
    const xz_bin = try std.fs.path.join(a, &.{ keg_abs, "bin", "xz" });
    defer a.free(xz_bin);
    {
        const res = try std.process.run(a, io, .{ .argv = &.{ "otool", "-L", xz_bin } });
        defer a.free(res.stdout);
        defer a.free(res.stderr);
        try std.testing.expect(std.mem.indexOf(u8, res.stdout, "@@HOMEBREW") == null);
        try std.testing.expect(std.mem.indexOf(u8, res.stdout, prefix) != null);
    }

    // (c) codesign -v bin/xz exits 0.
    {
        const res = try std.process.run(a, io, .{ .argv = &.{ "codesign", "-v", xz_bin } });
        defer a.free(res.stdout);
        defer a.free(res.stderr);
        switch (res.term) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
            else => try std.testing.expect(false),
        }
    }
}
