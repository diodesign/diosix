// RISC-V Physical Memory Protection (PMP) Management
// Used as a fallback for guest isolation when H-extension is missing.

const std = @import("std");
const physmem = @import("physmem.zig");
const debug = @import("debug.zig");

pub const PMPError = error{
    TooManyRegions,
    InvalidAlignment,
};

pub const PMPAccess = struct {
    pub const read = 1 << 0;
    pub const write = 1 << 1;
    pub const execute = 1 << 2;
    pub const tor = 1 << 3; // Top of Range mode (uses two entries)
};

pub const Region = struct {
    base: usize,
    size: usize,
    flags: u8,
};

pub const PMPConfig = struct {
    regions: std.ArrayList(Region),
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) !PMPConfig {
        return PMPConfig{
            .regions = std.ArrayList(Region).empty,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *PMPConfig) void {
        for (self.regions.items) |reg| {
            physmem.freePage(reg.base); 
        }
        self.regions.deinit(self.allocator);
    }

    pub fn addRegion(self: *PMPConfig, base: usize, size: usize, flags: u8) !void {
        // PMP usually has 16 entries. TOR mode uses 2 entries per region.
        // We reserve 1 slot (2 entries) for the root VM as requested.
        if (self.regions.items.len >= 7) return PMPError.TooManyRegions;
        
        try self.regions.append(self.allocator, .{ .base = base, .size = size, .flags = flags });
    }

    pub fn fork(self: *PMPConfig, allocator: std.mem.Allocator) !PMPConfig {
        var other = try PMPConfig.init(allocator);
        for (self.regions.items) |reg| {
            // "Copy entirely on fork" as requested for PMP fallback
            const new_base = try physmem.allocPageSelection(@intCast(std.math.log2(reg.size / physmem.PageSize)));
            @memcpy(@as([*]u8, @ptrFromInt(new_base))[0..reg.size], @as([*]u8, @ptrFromInt(reg.base))[0..reg.size]);
            try other.addRegion(new_base, reg.size, reg.flags);
        }
        return other;
    }

    // Apply this PMP configuration to the current physical core.
    // Called during context switch to a guest vcore.
    pub fn apply(self: *PMPConfig) void {
        _ = self;
        // Implement CSR writes for pmpaddrN and pmpcfgN
        // This is highly platform specific.
    }
};
