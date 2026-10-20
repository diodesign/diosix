// Root VM sizing policy, bootargs sanitization, and host peripheral discovery.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const riscv = @import("../../hardware/native/cpu/riscv64/mod.zig");
const dt = @import("../dt.zig");
const boot = @import("../boot.zig");

/// Computes Root VM RAM allocation from total host physical RAM.
pub fn computeRootVmRamBytes(total_host_ram_bytes: usize) usize {
    if (total_host_ram_bytes == 0) return boot.MIN_ROOT_VM_RAM_SIZE_BYTES;
    const align_2mb: usize = 2 * 1024 * 1024;
    if (total_host_ram_bytes < boot.MIN_HOST_RAM_SIZE_BYTES) {
        const half =
            std.mem.alignBackward(usize, total_host_ram_bytes / 2, align_2mb);
        const res: usize = @max(align_2mb, half);
        return res;
    }
    const scaled = std.mem.alignBackward(
        usize,
        total_host_ram_bytes / boot.ROOT_RAM_HOST_DIVISOR,
        align_2mb,
    );
    return std.math.clamp(
        scaled,
        boot.MIN_ROOT_VM_RAM_SIZE_BYTES,
        boot.MAX_ROOT_VM_RAM_SIZE_BYTES,
    );
}

/// Computes Root VM virtual CPU count from total discovered host CPUs.
pub fn computeRootVmVcpuCount(host_cpu_count: usize) usize {
    if (host_cpu_count == 0) return boot.MAX_ROOT_VM_VCPU_COUNT;
    return std.math.clamp(
        host_cpu_count,
        boot.MIN_ROOT_VM_VCPU_COUNT,
        boot.MAX_ROOT_VM_VCPU_COUNT,
    );
}

/// Sanitizes host-supplied `/chosen/bootargs` by stripping control characters,
/// collapsing consecutive whitespace, and bounding length to `buf.len`.
pub fn sanitizeBootargs(buf: []u8, raw: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    var out_len: usize = 0;
    var prev_space: bool = false;
    for (trimmed) |ch| {
        if (out_len >= buf.len) break;
        const norm: u8 =
            if (!std.ascii.isControl(ch) and ch != ' ') ch else ' ';
        if (norm == ' ') {
            if (prev_space) continue;
            prev_space = true;
        } else {
            prev_space = false;
        }
        buf[out_len] = norm;
        out_len += 1;
    }
    return std.mem.trimEnd(u8, buf[0..out_len], " ");
}

pub fn discoverHostPeripherals(device_tree: *const dt.DeviceTree) !void {
    var dt_it = device_tree.iter("/", boot.MAX_DT_DISCOVERY_DEPTH);
    while (dt_it.next()) |path| {
        const compat_prop = device_tree.getProperty(path, "compatible") catch
            continue;
        const compat_text = compat_prop.asText() catch continue;

        if (std.mem.indexOf(u8, compat_text, "clint") != null or
            std.mem.indexOf(u8, compat_text, "sifive,clint0") != null)
        {
            if (try device_tree.readAddress(path)) |addr| {
                riscv.clint_base = addr;
            }
        } else if (std.mem.indexOf(u8, compat_text, "ns16550a") != null or
            std.mem.indexOf(u8, compat_text, "uart") != null)
        {
            if (try device_tree.readAddress(path)) |addr| {
                riscv.uart_base = addr;
            }
        } else if (std.mem.indexOf(u8, compat_text, "sifive,test") != null) {
            if (try device_tree.readAddress(path)) |addr| {
                riscv.test_device_base = addr;
            }
        } else if (std.mem.indexOf(u8, compat_text, "plic") != null or
            std.mem.indexOf(u8, compat_text, "sifive,plic") != null)
        {
            if (try device_tree.readAddress(path)) |addr| {
                riscv.plic_base = addr;
            }
        }
    }
}

test "boot policy RAM scaling, vCPU clamping, and bootargs sanitization" {
    std.testing.refAllDecls(@This());
    const testing = std.testing;
    var buf: [32]u8 = undefined;
    const s1 = sanitizeBootargs(&buf, "  diosix.mode=dev\n\tdiosix.ui=gui  ");
    try testing.expectEqualStrings("diosix.mode=dev diosix.ui=gui", s1);
    const raw2 = "diosix.mode=live\x1b[2J  \x7fdiosix.ui=tui";
    const s2 = sanitizeBootargs(&buf, raw2);
    try testing.expectEqualStrings("diosix.mode=live [2J diosix.ui=t", s2);

    const mib: usize = 1024 * 1024;
    const gib: usize = 1024 * mib;
    try testing.expectEqual(128 * mib, computeRootVmRamBytes(512 * mib));
    try testing.expectEqual(128 * mib, computeRootVmRamBytes(1 * gib));
    try testing.expectEqual(192 * mib, computeRootVmRamBytes(1536 * mib));
    try testing.expectEqual(256 * mib, computeRootVmRamBytes(2 * gib));
    try testing.expectEqual(256 * mib, computeRootVmRamBytes(128 * gib));
    try testing.expectEqual(@as(usize, 4), computeRootVmVcpuCount(0));
    try testing.expectEqual(@as(usize, 1), computeRootVmVcpuCount(1));
    try testing.expectEqual(@as(usize, 2), computeRootVmVcpuCount(2));
    try testing.expectEqual(@as(usize, 4), computeRootVmVcpuCount(64));
}
