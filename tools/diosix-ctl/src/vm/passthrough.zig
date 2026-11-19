// Guest Device Passthrough CLI Parsing and Hypercall Configuration Helpers.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const api = @import("../api.zig");
const common = @import("../common.zig");

pub const MAX_PASSTHROUGH_RANGES: usize = 16;
pub const MAX_PASSTHROUGH_IRQS: usize = 32;
pub const MAX_KEEP_FDT_PREFIXES: usize = 16;

const PAGE_MASK: u64 = 0xfff;
const PLIC_MAX_PHYS_IRQ: u32 = 1024;
const PLIC_MIN_VIRT_IRQ: u32 = 16;
const PLIC_MAX_VIRT_IRQ: u32 = 128;

pub const MmioRangeSpec = struct {
    host_pa: u64,
    size: u64,
    read_only: bool = false,
};

pub const IrqSpec = struct {
    phys_irq: u32,
    virt_irq: u32 = 0,
};

pub fn parseMmioSpec(raw: []const u8) !MmioRangeSpec {
    var it = std.mem.splitScalar(u8, raw, ':');
    const addr_s = it.next() orelse return error.InvalidMmioSpec;
    const size_s = it.next() orelse return error.InvalidMmioSpec;
    const mode_opt = it.next();
    if (it.next() != null) return error.InvalidMmioSpec;

    const host_pa = std.fmt.parseInt(u64, addr_s, 0) catch
        return error.InvalidMmioSpec;
    const size = std.fmt.parseInt(u64, size_s, 0) catch
        return error.InvalidMmioSpec;
    if (size == 0 or size > api.MAX_CHILD_MMIO_SIZE_BYTES) {
        return error.InvalidMmioSpec;
    }
    if ((host_pa & PAGE_MASK) != 0 or (size & PAGE_MASK) != 0) {
        return error.InvalidMmioSpec;
    }
    _ = std.math.add(u64, host_pa, size) catch return error.InvalidMmioSpec;

    var read_only = false;
    if (mode_opt) |m| {
        if (std.mem.eql(u8, m, "ro")) {
            read_only = true;
        } else if (!std.mem.eql(u8, m, "rw")) {
            return error.InvalidMmioSpec;
        }
    }

    return .{ .host_pa = host_pa, .size = size, .read_only = read_only };
}

pub fn parseIrqSpec(raw: []const u8) !IrqSpec {
    var it = std.mem.splitScalar(u8, raw, ':');
    const phys_s = it.next() orelse return error.InvalidIrqSpec;
    const virt_opt = it.next();
    if (it.next() != null) return error.InvalidIrqSpec;

    const phys_irq = std.fmt.parseInt(u32, phys_s, 0) catch
        return error.InvalidIrqSpec;
    if (phys_irq == 0 or phys_irq >= PLIC_MAX_PHYS_IRQ) {
        return error.InvalidIrqSpec;
    }

    var virt_irq: u32 = 0;
    if (virt_opt) |vs| {
        virt_irq = std.fmt.parseInt(u32, vs, 0) catch
            return error.InvalidIrqSpec;
        if (virt_irq < PLIC_MIN_VIRT_IRQ or virt_irq >= PLIC_MAX_VIRT_IRQ) {
            return error.InvalidIrqSpec;
        }
    } else if (phys_irq < PLIC_MIN_VIRT_IRQ or phys_irq >= PLIC_MAX_VIRT_IRQ) {
        return error.InvalidIrqSpec;
    }

    return .{ .phys_irq = phys_irq, .virt_irq = virt_irq };
}

pub fn applyChildPassthrough(
    client: *api.DiosixClient,
    child_cid: usize,
    dma_trusted: bool,
    mmios: []const MmioRangeSpec,
    irqs: []const IrqSpec,
) !void {
    for (mmios) |m| {
        var flags: u64 = 0;
        if (m.read_only) {
            flags |= api.MmioPassFlags.READ_ONLY;
        } else if (dma_trusted) {
            flags |= api.MmioPassFlags.DMA_TRUSTED;
        }
        try client.mapChildMmio(
            child_cid,
            m.host_pa,
            m.host_pa,
            @intCast(m.size),
            flags,
        );
    }

    for (irqs) |q| {
        _ = try client.delegateChildIrq(child_cid, q.phys_irq, q.virt_irq, 0);
    }
}

pub fn configureChildPassthrough(
    client: *api.DiosixClient,
    child_cid: usize,
    dma_trusted: bool,
    mmios: []const MmioRangeSpec,
    irqs: []const IrqSpec,
    default_base_gpa: usize,
) !usize {
    var eff_base_gpa = default_base_gpa;
    if (dma_trusted) {
        const ram = try client.queryChildRam(child_cid);
        if (ram.gpa_base == 0 or ram.hpa_base == 0) {
            return error.PermissionDenied;
        }
        eff_base_gpa = @intCast(ram.gpa_base);
    }
    if (mmios.len > 0 or irqs.len > 0) {
        try applyChildPassthrough(client, child_cid, dma_trusted, mmios, irqs);
    }
    return eff_base_gpa;
}

pub fn reportPassthroughError(err: anyerror) void {
    if (err == error.PermissionDenied) {
        common.printStr(
            "Error: Hardware passthrough denied (writable MMIO on non-IOMMU " ++
                "hosts requires '--dma-trusted').\n",
        );
    } else {
        common.printApiError("Configure hardware passthrough", err);
    }
}

test "vm/passthrough: parseMmioSpec and parseIrqSpec validation" {
    std.testing.refAllDecls(@This());
    const testing = std.testing;

    const m1 = try parseMmioSpec("0x30000000:0x100000");
    try testing.expectEqual(@as(u64, 0x3000_0000), m1.host_pa);
    try testing.expectEqual(@as(u64, 0x10_0000), m1.size);
    try testing.expect(!m1.read_only);

    const m2 = try parseMmioSpec("0x10100000:4096:ro");
    try testing.expectEqual(@as(u64, 0x1010_0000), m2.host_pa);
    try testing.expectEqual(@as(u64, 4096), m2.size);
    try testing.expect(m2.read_only);

    try testing.expectError(
        error.InvalidMmioSpec,
        parseMmioSpec("0x30000001:4096"),
    );
    try testing.expectError(
        error.InvalidMmioSpec,
        parseMmioSpec("0x30000000:4096:bad"),
    );

    const q1 = try parseIrqSpec("32");
    try testing.expectEqual(@as(u32, 32), q1.phys_irq);
    try testing.expectEqual(@as(u32, 0), q1.virt_irq);

    const q2 = try parseIrqSpec("150:48");
    try testing.expectEqual(@as(u32, 150), q2.phys_irq);
    try testing.expectEqual(@as(u32, 48), q2.virt_irq);

    try testing.expectError(error.InvalidIrqSpec, parseIrqSpec("5"));
    try testing.expectError(error.InvalidIrqSpec, parseIrqSpec("150"));
}
