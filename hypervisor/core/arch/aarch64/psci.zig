// Arm Power State Coordination Interface (PSCI) implementation.
//
// Handles firmware calls from AArch64 guests via HVC/SMC instructions.
// Analogous to sbi.zig for RISC-V guests.
//
// Implements PSCI v1.1 (ARM DEN0022F) minimum viable subset:
//   - PSCI_VERSION, PSCI_FEATURES
//   - CPU_ON (stub for future multi-vcore)
//   - CPU_OFF, SYSTEM_RESET, SYSTEM_OFF
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const debug = @import("../../debug.zig");
const vcore = @import("../../vcore.zig");
const glue = @import("../../unicorn.zig");

// ---- PSCI Function IDs (SMCCC) ----

/// PSCI function IDs use the SMC Calling Convention (SMCCC):
///   bits [31:24] = calling convention (0x84 = SMC32 fast, 0xC4 = SMC64 fast)
///   bits [15:0]  = function number within PSCI

pub const PSCI_VERSION: u32 = 0x84000000;
pub const CPU_SUSPEND_32: u32 = 0x84000001;
pub const CPU_OFF: u32 = 0x84000002;
pub const CPU_ON_32: u32 = 0x84000003;
pub const AFFINITY_INFO_32: u32 = 0x84000004;
pub const MIGRATE_INFO_TYPE: u32 = 0x84000006;
pub const SYSTEM_OFF: u32 = 0x84000008;
pub const SYSTEM_RESET: u32 = 0x84000009;
pub const PSCI_FEATURES: u32 = 0x8400000A;

// SMC64 variants for 64-bit callers.
pub const CPU_SUSPEND_64: u32 = 0xC4000001;
pub const CPU_ON_64: u32 = 0xC4000003;
pub const AFFINITY_INFO_64: u32 = 0xC4000004;

// ---- PSCI Return Values ----

pub const SUCCESS: i64 = 0;
pub const NOT_SUPPORTED: i64 = -1;
pub const INVALID_PARAMETERS: i64 = -2;
pub const DENIED: i64 = -3;
pub const ALREADY_ON: i64 = -4;
pub const ON_PENDING: i64 = -5;
pub const INTERNAL_FAILURE: i64 = -6;

/// PSCI version: 1.1 (major=1, minor=1).
const VERSION_1_1: u32 = 0x00010001;

/// Handle a PSCI call from an AArch64 guest.
///
/// `func_id` is the PSCI function ID from W0 (X0 lower 32 bits).
/// `x1`-`x3` are the argument registers.
/// Returns the value to write to X0 (the result register).
pub fn handle(vc: *vcore.VirtualCore, func_id: u32, x1: u64, x2: u64, x3: u64) i64 {
    _ = x3;

    switch (func_id) {
        PSCI_VERSION => {
            return @as(i64, VERSION_1_1);
        },

        PSCI_FEATURES => {
            // Report which PSCI functions are supported.
            const queried = @as(u32, @truncate(x1));
            return switch (queried) {
                PSCI_VERSION,
                CPU_OFF,
                SYSTEM_RESET,
                SYSTEM_OFF,
                PSCI_FEATURES,
                CPU_ON_32,
                CPU_ON_64,
                => SUCCESS,
                else => NOT_SUPPORTED,
            };
        },

        CPU_ON_32, CPU_ON_64 => {
            // Target CPU = x1 (MPIDR), entry = x2, context_id = x3.
            // For single-vcore guests, any target other than 0 is invalid.
            const target_mpidr = x1;
            _ = x2; // entry_point — used when we support multi-vcore
            if (target_mpidr == 0) {
                return ALREADY_ON;
            }
            const S = struct {
                var log_count: u32 = 0;
            };
            if (S.log_count < 5) {
                S.log_count += 1;
                debug.printf("PSCI: CPU_ON target=0x{x} (multi-vcore not yet supported)\n", .{target_mpidr});
            }
            return INVALID_PARAMETERS;
        },

        CPU_OFF => {
            debug.printf("PSCI: CPU_OFF — halting vcore {}\n", .{vc.id});
            vc.state = .stopped;
            return SUCCESS;
        },

        SYSTEM_OFF => {
            debug.printf("PSCI: SYSTEM_OFF — shutting down guest {}\n", .{vc.guest_id});
            vc.guest.terminate();
            return SUCCESS;
        },

        SYSTEM_RESET => {
            debug.printf("PSCI: SYSTEM_RESET — resetting guest {}\n", .{vc.guest_id});
            vc.guest.state = .restarting;
            return SUCCESS;
        },

        MIGRATE_INFO_TYPE => {
            // Trusted OS migration not supported.
            return 2; // TOS not present
        },

        AFFINITY_INFO_32, AFFINITY_INFO_64 => {
            // Report affinity state. For single-vcore, CPU 0 is always ON.
            const target_mpidr = x1;
            if (target_mpidr == 0) return 0; // ON
            return 1; // OFF
        },

        CPU_SUSPEND_32, CPU_SUSPEND_64 => {
            // Treat as WFI — just return (the outer loop handles preemption).
            return SUCCESS;
        },

        else => {
            const S2 = struct {
                var log_count: u32 = 0;
            };
            if (S2.log_count < 10) {
                S2.log_count += 1;
                debug.printf("PSCI: unsupported function 0x{x}\n", .{func_id});
            }
            return NOT_SUPPORTED;
        },
    }
}
