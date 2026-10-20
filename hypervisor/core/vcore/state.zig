// Sub-vCore and emulated x86_64/IOAPIC/LAPIC state definitions for VirtualCore.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const vcore_mod = @import("../vcore.zig");
const guest = @import("../guest.zig");
const glue = @import("../emulation.zig");
const interface = @import("interface");

pub const IOAPIC_NUM_REDIR_ENTRIES: usize = 24;
pub const IOAPIC_REDIR_MASKED: u64 = 0x00010000;

pub const LAPIC_PAGE_SIZE: usize = 4096;
pub const LAPIC_LVT_MASKED: u32 = 0x00010000;
pub const LAPIC_REG_ID: usize = 0x20;
pub const LAPIC_REG_VERSION: usize = 0x30;
pub const LAPIC_REG_SPURIOUS: usize = 0xf0;
pub const LAPIC_VERSION_INTEGRATED: u32 = 0x00050014;
pub const LAPIC_SPURIOUS_ALL_MASKED: u32 = 0x000000ff;
pub const LAPIC_ID_SHIFT: u5 = 24;

pub const EMULATOR_STACK_SIZE_BYTES: usize = 2 * 1024 * 1024;
pub const EMULATOR_STACK_PAGE_ORDER: u8 = 9;
pub const EMULATOR_TLS_SIZE_BYTES: usize = 4096;
pub const EMULATOR_TLS_PAGE_ORDER: u8 = 0;
pub const EMULATOR_TLS_TP_OFFSET: usize = 2048;

pub const PIT_BASE_FREQUENCY_HZ: u64 = 1_193_182;
pub const PIT_DEFAULT_LATCH_100HZ: u64 = 11932;
pub const PIT_TIMER_ACCESS_LSB_MSB: u8 = 3;
pub const PIT_TIMER_MODE_SQUARE_WAVE: u8 = 3;

pub const max_sub_vcores: usize = 8;
pub const emulation_timeslice_instructions: u32 = 2_000_000;
pub const MAX_DEINIT_SPINS: usize = 100_000;

pub fn initIoapicRedtbl() [IOAPIC_NUM_REDIR_ENTRIES]u64 {
    var tbl: [IOAPIC_NUM_REDIR_ENTRIES]u64 = undefined;
    for (&tbl) |*entry| entry.* = IOAPIC_REDIR_MASKED;
    return tbl;
}

pub const LapicTimerState = struct {
    lvt_timer: u32 = LAPIC_LVT_MASKED,
    init_count: u32 = 0,
    divide_cfg: u32 = 0,
    start_time: u64 = 0,
    period_ticks: u64 = 0,
};

pub const SubVcoreState = struct {
    id: usize = 0,
    state: vcore_mod.VirtualCoreState = .stopped,
    context: ?*anyopaque = null,
    timer_scheduled: bool = false,
    timer_target: u64 = 0,
    wfi_blocked: bool = false,
    pending_ipi: bool = false,
    pending_ipi_vector: u8 = 0,
    start_pc: u64 = 0,
    start_a0: u64 = 0,
    start_a1: u64 = 0,
    last_pc: u64 = 0,
    lapic_timer: LapicTimerState = .{},
    icr_dest: u32 = 0,
    last_page_fault_addr: u64 = 0,
    freeze_count: u32 = 0,
    fs_base: u64 = 0,
    gs_base: u64 = 0,
    kernel_gs_base: u64 = 0,
};

pub fn initX86PeripheralState(
    vc: *vcore_mod.VirtualCore,
    parent: *guest.Guest,
    id: vcore_mod.VirtualCoreID,
) void {
    const init_latch: u64 = PIT_DEFAULT_LATCH_100HZ;
    const period_clint: u64 =
        (init_latch * interface.sbi.HOST_TIMER_FREQ_HZ) /
        PIT_BASE_FREQUENCY_HZ;
    parent.pit.channels[0] = .{
        .latch = @intCast(init_latch),
        .access = PIT_TIMER_ACCESS_LSB_MSB,
        .mode = PIT_TIMER_MODE_SQUARE_WAVE,
        .period_ticks = period_clint,
    };
    const em = &vc.exec_path.emulated;
    em.sub_vcores[0].timer_scheduled = true;
    em.sub_vcores[0].timer_target = glue.readSModeTime() + period_clint;

    const apic_id = @as(u32, @intCast(id)) << LAPIC_ID_SHIFT;
    const id_buf = em.lapic_mem[LAPIC_REG_ID..][0..4];
    const ver_buf = em.lapic_mem[LAPIC_REG_VERSION..][0..4];
    const spur_buf = em.lapic_mem[LAPIC_REG_SPURIOUS..][0..4];
    std.mem.writeInt(u32, id_buf, apic_id, .little);
    std.mem.writeInt(u32, ver_buf, LAPIC_VERSION_INTEGRATED, .little);
    std.mem.writeInt(u32, spur_buf, LAPIC_SPURIOUS_ALL_MASKED, .little);
}

test "VirtualCore sub-vcore state defaults" {
    std.testing.refAllDecls(@This());
    const tbl = initIoapicRedtbl();
    try std.testing.expectEqual(IOAPIC_REDIR_MASKED, tbl[0]);
}
