//! metalbrew library root.
const std = @import("std");

pub const domain = struct {
    pub const version = @import("domain/version.zig");
};

test {
    _ = @import("domain/version.zig");
}
