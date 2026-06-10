const std = @import("std");

/// Driven port: persistence of the raw downloaded index document.
pub const IndexCache = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        read: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!?[]u8,
        write: *const fn (ptr: *anyopaque, bytes: []const u8) anyerror!void,
    };

    pub fn read(self: IndexCache, allocator: std.mem.Allocator) anyerror!?[]u8 {
        return self.vtable.read(self.ptr, allocator);
    }
    pub fn write(self: IndexCache, bytes: []const u8) anyerror!void {
        return self.vtable.write(self.ptr, bytes);
    }
};
