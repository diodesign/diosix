// Mock RISC-V hardware symbols and context for host-side unit testing.
//
// Copyright (c) 2024-2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const atomic = @import("../../../../core/atomic.zig");
const riscv = @import("mod.zig");
const csr = @import("csr.zig");

const is_test = builtin.is_test;

pub const MOCK_RAM_SIZE: usize = 1024 * 1024;
pub const MOCK_RAM_ALIGN: usize = 4096;

pub var test_cpu_ctx: riscv.CpuContext = undefined;
pub var test_heap: [MOCK_RAM_SIZE]u8 align(MOCK_RAM_ALIGN) = undefined;

fn hw_putchar_mock(_: u8) callconv(.c) void {}
fn hw_pause_mock() callconv(.c) void {}
fn hw_pmp_init_mock() callconv(.c) void {}
fn hw_reboot_mock() callconv(.c) void {}
fn hw_shutdown_mock() callconv(.c) void {}
fn hw_set_timer_mock(_: u64) callconv(.c) void {}
fn hw_xint_init_mock() callconv(.c) void {}
fn hw_run_vcore_mock(
    _: *riscv.ThreadContext,
    _: *const riscv.MachineState,
    _: *const riscv.GuestState,
) callconv(.c) noreturn {
    while (true) {}
}
fn hw_dynarec_run_block_mock(_: *[32]u64, _: usize) callconv(.c) usize {
    return 0;
}
fn hw_dynarec_exit_mock() callconv(.c) void {}

pub export fn hw_private_variables_mock() *riscv.CpuContext {
    return &test_cpu_ctx;
}
pub export fn hw_heap_base_mock() usize {
    return @intFromPtr(&test_heap);
}
pub export fn hw_heap_size_mock() usize {
    return test_heap.len;
}

const mock_hypervisor_start: u8 = 0;
const mock_data_start: u8 = 0;
const mock_hypervisor_end: u8 = 0;

comptime {
    if (is_test) {
        const strong = std.builtin.GlobalLinkage.strong;
        @export(&mock_hypervisor_start, .{
            .name = "__hypervisor_start",
            .linkage = strong,
        });
        @export(&mock_data_start, .{
            .name = "__data_start",
            .linkage = strong,
        });
        @export(&mock_hypervisor_end, .{
            .name = "__hypervisor_end",
            .linkage = strong,
        });
        @export(&hw_putchar_mock, .{ .name = "hw_putchar", .linkage = strong });
        @export(&hw_pause_mock, .{ .name = "hw_pause", .linkage = strong });
        @export(&hw_pmp_init_mock, .{
            .name = "hw_pmp_init",
            .linkage = strong,
        });
        @export(&hw_reboot_mock, .{ .name = "hw_reboot", .linkage = strong });
        @export(&hw_shutdown_mock, .{
            .name = "hw_shutdown",
            .linkage = strong,
        });
        @export(&hw_set_timer_mock, .{
            .name = "hw_set_timer",
            .linkage = strong,
        });
        @export(&hw_private_variables_mock, .{
            .name = "hw_private_variables",
            .linkage = strong,
        });
        @export(&hw_heap_base_mock, .{
            .name = "hw_heap_base",
            .linkage = strong,
        });
        @export(&hw_heap_size_mock, .{
            .name = "hw_heap_size",
            .linkage = strong,
        });
        @export(&hw_xint_init_mock, .{
            .name = "hw_xint_init",
            .linkage = strong,
        });
        @export(&hw_run_vcore_mock, .{
            .name = "hw_run_vcore",
            .linkage = strong,
        });
        @export(&hw_dynarec_run_block_mock, .{
            .name = "hw_dynarec_run_block",
            .linkage = strong,
        });
        @export(&hw_dynarec_exit_mock, .{
            .name = "hw_dynarec_exit",
            .linkage = strong,
        });
    }
}

pub fn initMockHardware() void {
    if (!is_test) return;
    @memset(std.mem.asBytes(&test_cpu_ctx), 0);
    test_cpu_ctx.run_queue.init();
    test_cpu_ctx.blocked_queue.init();
    test_cpu_ctx.blocked_lock = atomic.SpinLock.init();
    test_cpu_ctx.in_m_mode = true;
    riscv.test_time = 0;
    csr.resetMockCsrs();
    @memset(&test_heap, 0);
}

test {
    std.testing.refAllDecls(@This());
}
