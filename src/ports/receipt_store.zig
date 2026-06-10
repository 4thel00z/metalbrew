const std = @import("std");

/// One installed-keg record.
pub const Receipt = struct {
    name: []const u8,
    version: []const u8,
};

/// Driven port: persistence of which kegs are installed.
pub const ReceiptStore = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        put: *const fn (ptr: *anyopaque, r: Receipt) anyerror!void,
        get: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!?Receipt,
        list: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]Receipt,
        remove: *const fn (ptr: *anyopaque, name: []const u8) anyerror!void,
    };

    pub fn put(self: ReceiptStore, r: Receipt) anyerror!void {
        return self.vtable.put(self.ptr, r);
    }
    pub fn get(self: ReceiptStore, allocator: std.mem.Allocator, name: []const u8) anyerror!?Receipt {
        return self.vtable.get(self.ptr, allocator, name);
    }
    pub fn list(self: ReceiptStore, allocator: std.mem.Allocator) anyerror![]Receipt {
        return self.vtable.list(self.ptr, allocator);
    }
    pub fn remove(self: ReceiptStore, name: []const u8) anyerror!void {
        return self.vtable.remove(self.ptr, name);
    }
};
