// ARM Power State Coordination Interface (PSCI v1.1) Emulation for Diosix
//
// Implements standard ARM DEN0022D PSCI function calls invoked via HVC/SMC
// by AArch64 guest kernels for SMP secondary core bring-up, affinity queries,
// and system power-off/reset.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const vcore = @import("../../../../core/vcore.zig");
const scheduler = @import("../../../../core/scheduler.zig");

pub const REG_X0_MAPPED: u5 = 31;

pub const PSCI_VERSION_1_1: i32 = 0x0001_0001;

// PSCI return codes (ARM DEN0022D Table 5).
pub const PSCI_SUCCESS: i32 = 0;
pub const PSCI_NOT_SUPPORTED: i32 = -1;
pub const PSCI_INVALID_PARAMETERS: i32 = -2;
pub const PSCI_DENIED: i32 = -3;
pub const PSCI_ALREADY_ON: i32 = -4;
pub const PSCI_ON_PENDING: i32 = -5;
pub const PSCI_INTERNAL_FAILURE: i32 = -6;

// PSCI AFFINITY_INFO return states.
pub const PSCI_AFFINITY_LEVEL_ON: i32 = 0;
pub const PSCI_AFFINITY_LEVEL_OFF: i32 = 1;
pub const PSCI_AFFINITY_MGR_NOT_PRESENT: i32 = 2;

// PSCI function identifiers (SMC32 / SMC64).
pub const PSCI_VERSION: u32 = 0x8400_0000;
pub const PSCI_CPU_SUSPEND_32: u32 = 0x8400_0001;
pub const PSCI_CPU_SUSPEND_64: u32 = 0xc400_0001;
pub const PSCI_CPU_OFF: u32 = 0x8400_0002;
pub const PSCI_CPU_ON_32: u32 = 0x8400_0003;
pub const PSCI_CPU_ON_64: u32 = 0xc400_0003;
pub const PSCI_AFFINITY_INFO_32: u32 = 0x8400_0004;
pub const PSCI_AFFINITY_INFO_64: u32 = 0xc400_0004;
pub const PSCI_MIGRATE_INFO_TYPE: u32 = 0x8400_0006;
pub const PSCI_SYSTEM_OFF: u32 = 0x8400_0008;
pub const PSCI_SYSTEM_RESET: u32 = 0x8400_0009;
pub const PSCI_FEATURES: u32 = 0x8400_000a;

pub const MPIDR_AFF0_MASK: u64 = 0xffff;

pub fn isSupportedFeature(func_id: u32) bool {
    return switch (func_id) {
        PSCI_VERSION,
        PSCI_CPU_SUSPEND_32,
        PSCI_CPU_SUSPEND_64,
        PSCI_CPU_OFF,
        PSCI_CPU_ON_32,
        PSCI_CPU_ON_64,
        PSCI_AFFINITY_INFO_32,
        PSCI_AFFINITY_INFO_64,
        PSCI_MIGRATE_INFO_TYPE,
        PSCI_SYSTEM_OFF,
        PSCI_SYSTEM_RESET,
        PSCI_FEATURES,
        => true,
        else => false,
    };
}

pub fn handlePSCI(
    vc: *vcore.VirtualCore,
    sub_idx: usize,
    func_id: u32,
    arg0: u64,
    arg1: u64,
    arg2: u64,
) i32 {
    _ = sub_idx;
    return switch (func_id) {
        PSCI_VERSION => PSCI_VERSION_1_1,
        PSCI_CPU_SUSPEND_32, PSCI_CPU_SUSPEND_64 => PSCI_SUCCESS,
        PSCI_CPU_OFF => {
            vc.state = .stopped;
            return PSCI_SUCCESS;
        },
        PSCI_CPU_ON_32, PSCI_CPU_ON_64 => {
            if (arg1 == 0) return PSCI_INVALID_PARAMETERS;
            const target_id: usize = @truncate(arg0 & MPIDR_AFF0_MASK);
            const target_vc = vc.guest.findVcore(target_id) orelse
                return PSCI_INVALID_PARAMETERS;
            if (target_vc.state == .running or target_vc.state == .ready) {
                return PSCI_ALREADY_ON;
            }
            if (target_vc.exec_path == .emulated) {
                target_vc.exec_path.emulated.entry = @truncate(arg1);
                target_vc.exec_path.emulated.dtb = @truncate(arg2);
                target_vc.exec_path.emulated.hsm_started = true;
                if (target_vc.exec_path.emulated.vcpu) |vcpu_ptr| {
                    vcpu_ptr.pc = @truncate(arg1);
                    vcpu_ptr.setReg(REG_X0_MAPPED, arg2);
                    vcpu_ptr.running = true;
                }
            }
            target_vc.state = .ready;
            scheduler.queue(target_vc);
            return PSCI_SUCCESS;
        },
        PSCI_AFFINITY_INFO_32, PSCI_AFFINITY_INFO_64 => {
            const target_id: usize = @truncate(arg0 & MPIDR_AFF0_MASK);
            const target_vc = vc.guest.findVcore(target_id) orelse
                return PSCI_INVALID_PARAMETERS;
            return if (target_vc.state == .stopped)
                PSCI_AFFINITY_LEVEL_OFF
            else
                PSCI_AFFINITY_LEVEL_ON;
        },
        PSCI_MIGRATE_INFO_TYPE => PSCI_AFFINITY_MGR_NOT_PRESENT,
        PSCI_SYSTEM_OFF => {
            vc.guest.terminateWithCode(0);
            return PSCI_SUCCESS;
        },
        PSCI_SYSTEM_RESET => {
            vc.guest.terminateWithCode(1);
            return PSCI_SUCCESS;
        },
        PSCI_FEATURES => {
            const queried_id: u32 = @truncate(arg0);
            return if (isSupportedFeature(queried_id))
                PSCI_SUCCESS
            else
                PSCI_NOT_SUPPORTED;
        },
        else => PSCI_NOT_SUPPORTED,
    };
}

test "PSCI handler: version, features, CPU_ON, and AFFINITY_INFO" {
    const testing = std.testing;
    testing.refAllDecls(@This());
    const guest_mod = @import("../../../../core/guest.zig");

    var phys_test = try @import("../../../../core/physmem.zig").initForTest(
        testing.allocator,
        1024,
    );
    defer phys_test.deinit();

    const g = try guest_mod.createGuest(
        testing.allocator,
        false,
        false,
        null,
        0x4000_0000,
        0x4000_0000,
        0x10_0000,
        .aarch64,
    );
    defer g.deinit();

    const vc0 = try g.addVcore(0, 0x4008_0000, 0x4400_0000, .normal, null);
    const vc1 = try g.addVcore(1, 0x4008_0000, 0x4400_0000, .normal, null);
    vc0.state = .running;
    vc1.state = .stopped;

    try testing.expectEqual(
        PSCI_VERSION_1_1,
        handlePSCI(vc0, 0, PSCI_VERSION, 0, 0, 0),
    );
    try testing.expectEqual(
        PSCI_SUCCESS,
        handlePSCI(vc0, 0, PSCI_FEATURES, PSCI_CPU_ON_64, 0, 0),
    );
    try testing.expectEqual(
        PSCI_NOT_SUPPORTED,
        handlePSCI(vc0, 0, PSCI_FEATURES, 0xdead_beef, 0, 0),
    );
    try testing.expectEqual(
        PSCI_AFFINITY_LEVEL_OFF,
        handlePSCI(vc0, 0, PSCI_AFFINITY_INFO_64, 1, 0, 0),
    );
    try testing.expectEqual(
        PSCI_SUCCESS,
        handlePSCI(vc0, 0, PSCI_CPU_ON_64, 1, 0x4008_1000, 0xcafe),
    );
    try testing.expectEqual(vcore.VirtualCoreState.ready, vc1.state);
    try testing.expectEqual(
        PSCI_ALREADY_ON,
        handlePSCI(vc0, 0, PSCI_CPU_ON_64, 1, 0x4008_1000, 0xcafe),
    );
}
