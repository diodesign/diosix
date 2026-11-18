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

fn isNodeEnabled(device_tree: *const dt.DeviceTree, path: []const u8) bool {
    const st_prop = device_tree.getProperty(path, "status") catch return true;
    const raw = st_prop.asText() catch return true;
    const st = std.mem.trim(u8, raw, " \t\r\n\x00");
    return std.mem.eql(u8, st, "okay") or std.mem.eql(u8, st, "ok");
}

fn resolveStdoutPath(
    device_tree: *const dt.DeviceTree,
    buf: *[128]u8,
) ?[]const u8 {
    const prop = device_tree.getProperty("/chosen", "stdout-path") catch
        return null;
    const raw = prop.asText() catch return null;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n\x00");
    const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse trimmed.len;
    var path = trimmed[0..colon];
    if (path.len == 0) return null;
    if (path[0] != '/') {
        const alias_p = device_tree.getProperty("/aliases", path) catch
            return null;
        const a_raw = alias_p.asText() catch return null;
        const a_trim = std.mem.trim(u8, a_raw, " \t\r\n\x00");
        const a_col = std.mem.indexOfScalar(u8, a_trim, ':') orelse a_trim.len;
        path = a_trim[0..a_col];
        if (path.len == 0 or path[0] != '/') return null;
    }
    if (path.len > buf.len) return null;
    @memcpy(buf[0..path.len], path);
    return buf[0..path.len];
}

fn applyUartNode(
    device_tree: *const dt.DeviceTree,
    path: []const u8,
    compat_text: []const u8,
) !bool {
    const addr = (try device_tree.readAddress(path)) orelse return false;
    if (addr == 0) return false;
    riscv.uart_base = addr;
    if (std.mem.indexOf(u8, compat_text, "sifive,uart0") != null) {
        riscv.uart_is_sifive = true;
        riscv.uart_reg_shift = 0;
        riscv.uart_reg_io_width = 4;
    } else if (std.mem.indexOf(u8, compat_text, "snps,dw-apb-uart") != null or
        std.mem.indexOf(u8, compat_text, "mrvl,pxa-uart") != null)
    {
        riscv.uart_is_sifive = false;
        riscv.uart_reg_shift = 2;
        riscv.uart_reg_io_width = 4;
    } else {
        riscv.uart_is_sifive = false;
        riscv.uart_reg_shift = 0;
        riscv.uart_reg_io_width = 1;
    }
    if (device_tree.getProperty(path, "reg-shift")) |p| {
        if (p.asU32()) |shift| {
            if (shift <= 4) riscv.uart_reg_shift = @intCast(shift);
        } else |_| {}
    } else |_| {}
    if (device_tree.getProperty(path, "reg-io-width")) |p| {
        if (p.asU32()) |width| {
            if (width == 1 or width == 4) {
                riscv.uart_reg_io_width = @intCast(width);
            }
        } else |_| {}
    } else |_| {}
    return true;
}

pub fn discoverHostPeripherals(device_tree: *const dt.DeviceTree) !void {
    var uart_found = false;
    var stdout_buf: [128]u8 = undefined;
    if (resolveStdoutPath(device_tree, &stdout_buf)) |sp| {
        if (isNodeEnabled(device_tree, sp)) {
            if (device_tree.getProperty(sp, "compatible")) |cp| {
                if (cp.asText()) |ct| {
                    uart_found = try applyUartNode(device_tree, sp, ct);
                } else |_| {}
            } else |_| {}
        }
    }

    var dt_it = device_tree.iter("/", boot.MAX_DT_DISCOVERY_DEPTH);
    while (dt_it.next()) |path| {
        if (!isNodeEnabled(device_tree, path)) continue;
        const compat_prop = device_tree.getProperty(path, "compatible") catch
            continue;
        const compat_text = compat_prop.asText() catch continue;

        if (std.mem.indexOf(u8, compat_text, "clint") != null or
            std.mem.indexOf(u8, compat_text, "sifive,clint0") != null)
        {
            if (try device_tree.readAddress(path)) |addr| {
                riscv.clint_base = addr;
            }
        } else if (!uart_found and
            (std.mem.indexOf(u8, compat_text, "sifive,uart0") != null or
                std.mem.indexOf(u8, compat_text, "snps,dw-apb-uart") != null or
                std.mem.indexOf(u8, compat_text, "mrvl,pxa-uart") != null or
                std.mem.indexOf(u8, compat_text, "ns16550a") != null or
                std.mem.indexOf(u8, compat_text, "uart") != null))
        {
            uart_found = try applyUartNode(device_tree, path, compat_text);
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
    const saved_u = riscv.uart_base;
    const saved_sh = riscv.uart_reg_shift;
    const saved_w = riscv.uart_reg_io_width;
    const saved_sf = riscv.uart_is_sifive;
    defer {
        riscv.uart_base = saved_u;
        riscv.uart_reg_shift = saved_sh;
        riscv.uart_reg_io_width = saved_w;
        riscv.uart_is_sifive = saved_sf;
    }

    const a = testing.allocator;
    const P = dt.DeviceTreeProperty;
    const t1 = try dt.DeviceTree.init(a);
    defer t1.deinit();
    try t1.editProperty("/soc", "#address-cells", try P.fromU32(a, 1));
    try t1.editProperty("/soc", "#size-cells", try P.fromU32(a, 1));
    try t1.editProperty(
        "/soc/uart@0",
        "compatible",
        try P.fromText(a, "ns16550a"),
    );
    try t1.editProperty("/soc/uart@0", "status", try P.fromText(a, "disabled"));
    try t1.editProperty(
        "/soc/uart@0",
        "reg",
        try P.fromMultiU32(a, &.{ 0x20000000, 0x100 }),
    );
    try t1.editProperty(
        "/soc/serial@10000000",
        "compatible",
        try P.fromText(a, "snps,dw-apb-uart"),
    );
    try t1.editProperty(
        "/soc/serial@10000000",
        "reg",
        try P.fromMultiU32(a, &.{ 0x10000000, 0x100 }),
    );
    try t1.editProperty(
        "/chosen",
        "stdout-path",
        try P.fromText(a, "/soc/serial@10000000:115200n8"),
    );
    try discoverHostPeripherals(t1);
    try testing.expectEqual(@as(?usize, 0x10000000), riscv.uart_base);
    try testing.expectEqual(@as(u3, 2), riscv.uart_reg_shift);
    try testing.expectEqual(@as(u8, 4), riscv.uart_reg_io_width);
    try testing.expect(!riscv.uart_is_sifive);

    const t2 = try dt.DeviceTree.init(a);
    defer t2.deinit();
    try t2.editProperty("/soc", "#address-cells", try P.fromU32(a, 1));
    try t2.editProperty(
        "/soc/serial@10010000",
        "compatible",
        try P.fromText(a, "sifive,uart0"),
    );
    try t2.editProperty(
        "/soc/serial@10010000",
        "reg",
        try P.fromMultiU32(a, &.{ 0x10010000, 0x100 }),
    );
    try t2.editProperty(
        "/aliases",
        "serial0",
        try P.fromText(a, "/soc/serial@10010000"),
    );
    try t2.editProperty(
        "/chosen",
        "stdout-path",
        try P.fromText(a, "serial0:115200"),
    );
    try discoverHostPeripherals(t2);
    try testing.expectEqual(@as(?usize, 0x10010000), riscv.uart_base);
    try testing.expect(riscv.uart_is_sifive);
    var buf: [32]u8 = undefined;
    const s1 = sanitizeBootargs(&buf, "  diosix.mode=dev\n\tdiosix.ui=gui  ");
    try testing.expectEqualStrings("diosix.mode=dev diosix.ui=gui", s1);
    const raw2 = "diosix.mode=live\x1b[2J  \x7fdiosix.ui=tui";
    const s2 = sanitizeBootargs(&buf, raw2);
    try testing.expectEqualStrings("diosix.mode=live [2J diosix.ui=t", s2);

    const mib: usize = 1024 * 1024;
    const gib: usize = 1024 * mib;
    try testing.expectEqual(128 * mib, computeRootVmRamBytes(512 * mib));
    try testing.expectEqual(256 * mib, computeRootVmRamBytes(1 * gib));
    try testing.expectEqual(384 * mib, computeRootVmRamBytes(1536 * mib));
    try testing.expectEqual(512 * mib, computeRootVmRamBytes(2 * gib));
    try testing.expectEqual(512 * mib, computeRootVmRamBytes(128 * gib));
    try testing.expectEqual(@as(usize, 4), computeRootVmVcpuCount(0));
    try testing.expectEqual(@as(usize, 1), computeRootVmVcpuCount(1));
    try testing.expectEqual(@as(usize, 2), computeRootVmVcpuCount(2));
    try testing.expectEqual(@as(usize, 4), computeRootVmVcpuCount(64));
}
