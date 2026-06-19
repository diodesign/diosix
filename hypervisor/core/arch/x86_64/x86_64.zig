// Architecture-specific emulation handler for 64-bit x86 guests.
//
// Stub implementation — to be completed when x86_64 guest support is added.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const emulation = @import("../../emulation.zig");
const glue = @import("../../unicorn.zig");
const vcore = @import("../../vcore.zig");
const debug = @import("../../debug.zig");

pub const ExceptionAction = emulation.ExceptionAction;

pub fn initRegisters(uc: ?*anyopaque, entry: usize, _: usize, _: usize) void {
    var pc_val: u64 = entry;
    _ = glue.uc_reg_write(uc, @intFromEnum(glue.uc_x86_reg.UC_X86_REG_RIP), &pc_val);
}

pub fn readPC(uc: ?*anyopaque) u64 {
    var pc: u64 = 0;
    _ = glue.uc_reg_read(uc, @intFromEnum(glue.uc_x86_reg.UC_X86_REG_RIP), &pc);
    return pc;
}

pub fn writePC(uc: ?*anyopaque, pc: u64) void {
    var val: u64 = pc;
    _ = glue.uc_reg_write(uc, @intFromEnum(glue.uc_x86_reg.UC_X86_REG_RIP), &val);
}

pub fn handleInvalidInsn(_: ?*anyopaque) bool {
    return false; // To be implemented: x86_64 RDTSC emulation.
}

pub fn handleCleanStop(_: ?*anyopaque, _: *vcore.VirtualCore, pc: u64) bool {
    debug.printf("x86_64: clean stop at PC 0x{x}, syscall handling not yet implemented\n", .{pc});
    return false;
}

pub fn handleException(_: ?*anyopaque, pc: u64) ExceptionAction {
    debug.printf("x86_64: exception at PC 0x{x}, handler not yet implemented\n", .{pc});
    return .unhandled;
}

pub fn translateVA(_: ?*anyopaque, _: u64) ?u64 {
    return null; // To be implemented: x86_64 CR3-based page table walk
}
