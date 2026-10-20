// Safe host-to-guest and guest-to-host physical memory transfer routines.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const physmem = @import("../physmem.zig");
const vm = @import("../vm.zig");

/// Safely copies data from a host buffer to guest physical memory space.
/// Pre-validates the entire GPA range to avoid partial writes.
pub fn copyToGuest(
    self: *const vm.GuestSpace,
    dst_gpa: usize,
    src: []const u8,
) !void {
    if (src.len == 0) return;
    _ = std.math.add(usize, dst_gpa, src.len) catch
        return error.TranslationFailed;

    // Pass 1: Pre-validate all target pages.
    var check_off: usize = 0;
    while (check_off < src.len) {
        const cur_gpa = dst_gpa + check_off;
        const cur_hpa = try self.translateGPA(cur_gpa);
        const page_rem = physmem.PageSize - (cur_gpa % physmem.PageSize);
        const chunk: usize = @min(src.len - check_off, page_rem);
        if (physmem.isHypervisorMemory(cur_hpa, chunk)) {
            return error.AccessDenied;
        }
        check_off += chunk;
    }

    // Pass 2: Transfer data page by page.
    var transferred: usize = 0;
    while (transferred < src.len) {
        const cur_gpa = dst_gpa + transferred;
        const cur_hpa = try self.translateGPA(cur_gpa);
        const page_rem = physmem.PageSize - (cur_gpa % physmem.PageSize);
        const chunk: usize = @min(src.len - transferred, page_rem);
        if (physmem.isHypervisorMemory(cur_hpa, chunk)) {
            return error.AccessDenied;
        }
        @memcpy(
            @as([*]u8, @ptrFromInt(cur_hpa))[0..chunk],
            src[transferred .. transferred + chunk],
        );
        transferred += chunk;
    }
}

/// Safely copies data from guest physical memory space into a host buffer.
/// Pre-validates the entire GPA range to avoid partial reads.
pub fn copyFromGuest(
    self: *const vm.GuestSpace,
    dst: []u8,
    src_gpa: usize,
) !void {
    if (dst.len == 0) return;
    _ = std.math.add(usize, src_gpa, dst.len) catch
        return error.TranslationFailed;

    // Pass 1: Pre-validate all source pages.
    var check_off: usize = 0;
    while (check_off < dst.len) {
        const cur_gpa = src_gpa + check_off;
        const cur_hpa = try self.translateGPA(cur_gpa);
        const page_rem = physmem.PageSize - (cur_gpa % physmem.PageSize);
        const chunk: usize = @min(dst.len - check_off, page_rem);
        if (physmem.isHypervisorMemory(cur_hpa, chunk)) {
            return error.AccessDenied;
        }
        check_off += chunk;
    }

    // Pass 2: Transfer data page by page.
    var transferred: usize = 0;
    while (transferred < dst.len) {
        const cur_gpa = src_gpa + transferred;
        const cur_hpa = try self.translateGPA(cur_gpa);
        const page_rem = physmem.PageSize - (cur_gpa % physmem.PageSize);
        const chunk: usize = @min(dst.len - transferred, page_rem);
        if (physmem.isHypervisorMemory(cur_hpa, chunk)) {
            return error.AccessDenied;
        }
        @memcpy(
            dst[transferred .. transferred + chunk],
            @as([*]const u8, @ptrFromInt(cur_hpa))[0..chunk],
        );
        transferred += chunk;
    }
}

/// Reads a typed struct from guest physical address space.
pub fn readGuestStruct(
    self: *const vm.GuestSpace,
    comptime T: type,
    gpa: usize,
) !T {
    var val: T = undefined;
    try copyFromGuest(self, std.mem.asBytes(&val), gpa);
    return val;
}

/// Writes a typed struct to guest physical address space.
pub fn writeGuestStruct(
    self: *const vm.GuestSpace,
    comptime T: type,
    gpa: usize,
    val: T,
) !void {
    try copyToGuest(self, gpa, std.mem.asBytes(&val));
}

test "GuestSpace safe copy and struct transfer across page boundaries" {
    std.testing.refAllDecls(@This());
    const testing = std.testing;

    var phys_test = try physmem.initForTest(testing.allocator, 128);
    defer phys_test.deinit();

    const base_gpa: usize = 0x80000000;
    const base_hpa = physmem.getRamBase() + 8 * physmem.PageSize;
    const size: usize = 2 * physmem.PageSize;

    var space = try vm.GuestSpace.init(
        testing.allocator,
        true,
        base_gpa,
        base_hpa,
        size,
    );
    defer space.deinit();

    const TestStruct = extern struct {
        a: u64,
        b: u64,
        c: u32,
    };

    const straddle_gpa = base_gpa + physmem.PageSize - 8;
    const original = TestStruct{
        .a = 0x1122334455667788,
        .b = 0x8877665544332211,
        .c = 0xdeadbeef,
    };

    try space.writeGuestStruct(TestStruct, straddle_gpa, original);
    const read_back = try space.readGuestStruct(TestStruct, straddle_gpa);
    try testing.expectEqual(original.a, read_back.a);
    try testing.expectEqual(original.b, read_back.b);
    try testing.expectEqual(original.c, read_back.c);

    const out_of_bounds_gpa = base_gpa + size - 4;
    try testing.expectError(
        error.TranslationFailed,
        space.writeGuestStruct(TestStruct, out_of_bounds_gpa, original),
    );
    try testing.expectError(
        error.TranslationFailed,
        space.writeGuestStruct(
            TestStruct,
            std.math.maxInt(usize) - 4,
            original,
        ),
    );

    const hv_hpa = physmem.getHvRegion().base;
    if (hv_hpa > 0) {
        var poisoned_space = try vm.GuestSpace.init(
            testing.allocator,
            false,
            0x1000,
            hv_hpa,
            physmem.PageSize,
        );
        defer poisoned_space.deinit();

        var dummy_buf: [16]u8 = @splat(0xaa);
        try testing.expectError(
            error.AccessDenied,
            poisoned_space.copyToGuest(0x1000, &dummy_buf),
        );
        try testing.expectError(
            error.AccessDenied,
            poisoned_space.copyFromGuest(&dummy_buf, 0x1000),
        );
    }
}
