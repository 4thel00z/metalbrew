const std = @import("std");
const Formula = @import("../domain/formula.zig").Formula;
const Dependency = @import("../domain/formula.zig").Dependency;
const BottleSpec = @import("../domain/formula.zig").BottleSpec;
const Version = @import("../domain/version.zig").Version;
const PackageCatalog = @import("../ports/catalog.zig").PackageCatalog;
const HttpClient = @import("http_client.zig").HttpClient;

/// Parse one formula object (/api/formula/<name>.json shape) into a domain Formula.
/// All slices allocated with `allocator`.
pub fn parseFormula(allocator: std.mem.Allocator, json_bytes: []const u8) !Formula {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();
    return try formulaFromValue(allocator, parsed.value);
}

/// PUBLIC so the cached full-index catalog (Task 9) can reuse it per array element.
pub fn formulaFromValue(allocator: std.mem.Allocator, value: std.json.Value) !Formula {
    const obj = value.object;
    const name = try allocator.dupe(u8, obj.get("name").?.string);
    const versions = obj.get("versions").?.object;
    const ver_raw = try allocator.dupe(u8, versions.get("stable").?.string);
    const desc = if (obj.get("desc")) |d| switch (d) {
        .string => |s| try allocator.dupe(u8, s),
        else => "",
    } else "";
    const homepage = if (obj.get("homepage")) |h| switch (h) {
        .string => |s| try allocator.dupe(u8, s),
        else => "",
    } else "";

    var deps: std.ArrayList(Dependency) = .empty;
    if (obj.get("dependencies")) |d| for (d.array.items) |item| {
        try deps.append(allocator, .{ .name = try allocator.dupe(u8, item.string) });
    };
    if (obj.get("build_dependencies")) |d| for (d.array.items) |item| {
        try deps.append(allocator, .{ .name = try allocator.dupe(u8, item.string), .build_only = true });
    };

    var bottles: std.ArrayList(BottleSpec) = .empty;
    if (obj.get("bottle")) |b| if (b.object.get("stable")) |stable| if (stable.object.get("files")) |files| {
        var it = files.object.iterator();
        while (it.next()) |entry| {
            const f = entry.value_ptr.*.object;
            try bottles.append(allocator, .{
                .tag = try allocator.dupe(u8, entry.key_ptr.*),
                .url = try allocator.dupe(u8, f.get("url").?.string),
                .sha256 = try allocator.dupe(u8, f.get("sha256").?.string),
            });
        }
    };

    return .{
        .name = name,
        .version = Version.init(ver_raw),
        .desc = desc,
        .homepage = homepage,
        .dependencies = try deps.toOwnedSlice(allocator),
        .bottles = try bottles.toOwnedSlice(allocator),
    };
}

/// Production PackageCatalog: fetches single formulae on demand from the API.
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
            error.HttpStatus => return null,
            else => return e,
        };
        defer allocator.free(body);
        return try parseFormula(allocator, body);
    }
    fn namesImpl(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![][]const u8 {
        _ = ptr;
        _ = allocator;
        return error.Unsupported;
    }
};

test "parseFormula extracts wget from fixture" {
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bytes = @embedFile("../testdata/wget.json");
    const f = try parseFormula(arena, bytes);
    try std.testing.expectEqualStrings("wget", f.name);
    try std.testing.expect(f.dependencies.len >= 1);
    var found = false;
    for (f.dependencies) |d| {
        if (std.mem.eql(u8, d.name, "libidn2")) found = true;
    }
    try std.testing.expect(found);
    try std.testing.expect(f.bottles.len >= 1); // wget has bottles
}
