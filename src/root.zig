//! metalbrew library root.
const std = @import("std");

pub const domain = struct {
    pub const version = @import("domain/version.zig");
    pub const formula = @import("domain/formula.zig");
    pub const resolver = @import("domain/resolver.zig");
};

pub const ports = struct {
    pub const catalog = @import("ports/catalog.zig");
    pub const index_cache = @import("ports/index_cache.zig");
};

test {
    _ = @import("domain/version.zig");
    _ = @import("domain/formula.zig");
    _ = @import("domain/resolver.zig");
    _ = @import("ports/catalog.zig");
    _ = @import("ports/index_cache.zig");
}
