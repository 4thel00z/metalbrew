//! metalbrew library root.
const std = @import("std");

pub const domain = struct {
    pub const version = @import("domain/version.zig");
    pub const formula = @import("domain/formula.zig");
};

test {
    _ = @import("domain/version.zig");
    _ = @import("domain/formula.zig");
}
