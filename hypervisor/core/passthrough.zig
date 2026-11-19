// Scoped Host MMIO Passthrough, DMA-Trust Gate, & Teardown Coordination.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const atomic = @import("atomic.zig");
const physmem = @import("physmem.zig");
const guest_mod = @import("guest.zig");
const vcore = @import("vcore.zig");
const sv39x4 = @import("../hardware/native/cpu/riscv64/sv39x4.zig");
const riscv = @import("../hardware/native/cpu/riscv64/mod.zig");
const interface = @import("interface").sbi;
const sbi_core = @import("sbi.zig");
const main = @import("../main.zig");

pub const plic = @import("passthrough/plic.zig");
pub const handleDelegateChildIrq = plic.handleDelegateChildIrq;
pub const handleMachineExternalIrq = plic.handleMachineExternalIrq;
pub const maybeNotifyGuestPlicWrite = plic.maybeNotifyGuestPlicWrite;
pub const hasActiveDelegatedIrqs = plic.hasActiveDelegatedIrqs;
pub const test_plic_base = &plic.test_plic_base;

pub const MAX_MAPPED_MMIO_REGIONS: usize = 64;
const HOST_PLIC_PROTECT_BYTES: usize = 0x40_0000;
const HOST_CLINT_PROTECT_BYTES: usize = 0x1_0000;

const VIRT_CLINT_BASE: u64 = 0x0200_0000;
const VIRT_CLINT_SIZE: u64 = 0x1_0000;
const VIRT_PLIC_BASE: u64 = 0x0c00_0000;
const VIRT_PLIC_SIZE: u64 = 0x0400_0000;
const VIRT_MMIO_BASE: u64 = 0x1000_0000;
const VIRT_MMIO_SIZE: u64 = 0x1_0000;

var mmio_lock = atomic.SpinLock.init();

const MappedMmioRegion = struct {
    active: bool = false,
    guest_id: usize = 0,
    host_pa: u64 = 0,
    child_gpa: u64 = 0,
    size: u64 = 0,
    read_only: bool = false,
};

var mmio_regions: [MAX_MAPPED_MMIO_REGIONS]MappedMmioRegion = @splat(.{});

pub fn resetForTest() void {
    plic.resetForTest();
    const s = mmio_lock.lock();
    defer mmio_lock.unlock(s);
    mmio_regions = @splat(.{});
}

fn rangesOverlap(a_start: u64, a_size: u64, b_start: u64, b_size: u64) bool {
    if (a_size == 0 or b_size == 0) return false;
    const a_end = std.math.add(u64, a_start, a_size) catch
        std.math.maxInt(u64);
    const b_end = std.math.add(u64, b_start, b_size) catch
        std.math.maxInt(u64);
    return a_start < b_end and b_start < a_end;
}

fn overlapsHostForbidden(
    parent: *guest_mod.Guest,
    host_pa: u64,
    size: u64,
) bool {
    const h_usize = std.math.cast(usize, host_pa) orelse return true;
    const s_usize = std.math.cast(usize, size) orelse return true;
    if (physmem.isHypervisorMemory(h_usize, s_usize)) return true;
    if (physmem.overlapsRam(h_usize, s_usize)) return true;
    if (parent.space.base_hpa != 0 and parent.space.range_size > 0 and
        rangesOverlap(
            host_pa,
            size,
            parent.space.base_hpa,
            parent.space.range_size,
        )) return true;
    if (main.global_root_vm) |root| {
        if (root != parent and root.space.base_hpa != 0 and
            root.space.range_size > 0 and rangesOverlap(
            host_pa,
            size,
            root.space.base_hpa,
            root.space.range_size,
        )) return true;
    }
    if (riscv.clint_base) |b| {
        if (rangesOverlap(host_pa, size, b, HOST_CLINT_PROTECT_BYTES)) {
            return true;
        }
    }
    if (riscv.plic_base) |b| {
        if (rangesOverlap(host_pa, size, b, HOST_PLIC_PROTECT_BYTES)) {
            return true;
        }
    }
    if (plic.test_plic_base) |b| {
        if (rangesOverlap(host_pa, size, b, HOST_PLIC_PROTECT_BYTES)) {
            return true;
        }
    }
    if (riscv.uart_base) |b| {
        if (rangesOverlap(host_pa, size, b, physmem.PageSize)) return true;
    }
    if (riscv.test_device_base) |b| {
        if (rangesOverlap(host_pa, size, b, physmem.PageSize)) return true;
    }
    return false;
}

fn overlapsChildForbidden(
    child: *guest_mod.Guest,
    child_gpa: u64,
    size: u64,
) bool {
    if (child.space.range_size > 0 and rangesOverlap(
        child_gpa,
        size,
        child.space.base_gpa,
        child.space.range_size,
    )) return true;
    if (rangesOverlap(child_gpa, size, VIRT_CLINT_BASE, VIRT_CLINT_SIZE)) {
        return true;
    }
    if (rangesOverlap(child_gpa, size, VIRT_PLIC_BASE, VIRT_PLIC_SIZE)) {
        return true;
    }
    if (rangesOverlap(child_gpa, size, VIRT_MMIO_BASE, VIRT_MMIO_SIZE)) {
        return true;
    }
    return false;
}

fn hostHasHardwareIommu() bool {
    return false;
}

pub fn handleMapChildMmio(
    vc: *vcore.VirtualCore,
    ctx: *riscv.ThreadContext,
    args_gpa: usize,
) void {
    const parent = vc.getGuest();
    const F = interface.MmioPassFlags;
    var args = parent.space.readGuestStruct(
        interface.MapChildMmioArgs,
        args_gpa,
    ) catch return sbi_core.setResult(
        vc,
        ctx,
        sbi_core.SBI_ERR_INVALID_ADDRESS,
        0,
    );

    if ((args.flags & ~F.VALID_MASK) != 0) {
        return sbi_core.setResult(vc, ctx, sbi_core.SBI_ERR_INVALID_PARAM, 0);
    }
    const child = parent.getGuestByCid(args.child_id) orelse
        return sbi_core.setResult(vc, ctx, sbi_core.SBI_ERR_INVALID_PARAM, 0);

    if ((args.flags & F.QUERY_RAM) != 0) {
        if (args.flags != F.QUERY_RAM) {
            return sbi_core.setResult(
                vc,
                ctx,
                sbi_core.SBI_ERR_INVALID_PARAM,
                0,
            );
        }
        const can_hpa = (parent.is_trusted or parent.has_host_passthrough) and
            child.is_dma_trusted and child.space.is_ram_allocated;
        args.child_gpa = child.space.base_gpa;
        args.size = child.space.range_size;
        args.host_pa = if (can_hpa) child.space.base_hpa else 0;
        parent.space.writeGuestStruct(
            interface.MapChildMmioArgs,
            args_gpa,
            args,
        ) catch return sbi_core.setResult(
            vc,
            ctx,
            sbi_core.SBI_ERR_INVALID_ADDRESS,
            0,
        );
        return sbi_core.setResult(vc, ctx, sbi_core.SBI_SUCCESS, 0);
    }

    if (!parent.is_trusted and !parent.has_host_passthrough) {
        return sbi_core.setResult(vc, ctx, sbi_core.SBI_ERR_DENIED, 0);
    }
    if (child.target_arch != .riscv64 or child.space.mode != .h_paging) {
        return sbi_core.setResult(vc, ctx, sbi_core.SBI_ERR_NOT_SUPPORTED, 0);
    }
    if (args.size == 0 or args.size > interface.MAX_CHILD_MMIO_SIZE_BYTES) {
        return sbi_core.setResult(vc, ctx, sbi_core.SBI_ERR_INVALID_PARAM, 0);
    }
    const pg_mask: u64 = physmem.PageSize - 1;
    if ((args.host_pa & pg_mask) != 0 or (args.child_gpa & pg_mask) != 0 or
        (args.size & pg_mask) != 0)
    {
        return sbi_core.setResult(vc, ctx, sbi_core.SBI_ERR_INVALID_PARAM, 0);
    }
    _ = std.math.add(u64, args.host_pa, args.size) catch
        return sbi_core.setResult(vc, ctx, sbi_core.SBI_ERR_INVALID_PARAM, 0);
    const gpa_end = std.math.add(u64, args.child_gpa, args.size) catch
        return sbi_core.setResult(vc, ctx, sbi_core.SBI_ERR_INVALID_PARAM, 0);
    if (gpa_end > sv39x4.MAX_GPA) {
        return sbi_core.setResult(vc, ctx, sbi_core.SBI_ERR_INVALID_PARAM, 0);
    }

    const is_ro = (args.flags & F.READ_ONLY) != 0;
    const flag_dma = (args.flags & F.DMA_TRUSTED) != 0;
    if (!is_ro and !hostHasHardwareIommu() and
        !(child.is_dma_trusted and flag_dma))
    {
        return sbi_core.setResult(vc, ctx, sbi_core.SBI_ERR_DENIED, 0);
    }
    if (overlapsHostForbidden(parent, args.host_pa, args.size) or
        overlapsChildForbidden(child, args.child_gpa, args.size))
    {
        return sbi_core.setResult(vc, ctx, sbi_core.SBI_ERR_DENIED, 0);
    }

    const s = mmio_lock.lock();
    defer mmio_lock.unlock(s);

    var free_slot: ?*MappedMmioRegion = null;
    for (&mmio_regions) |*r| {
        if (!r.active) {
            if (free_slot == null) free_slot = r;
            continue;
        }
        if (r.guest_id == child.id) {
            if (rangesOverlap(args.child_gpa, args.size, r.child_gpa, r.size)) {
                return sbi_core.setResult(
                    vc,
                    ctx,
                    sbi_core.SBI_ERR_ALREADY_AVAILABLE,
                    0,
                );
            }
        } else if ((!is_ro or !r.read_only) and
            rangesOverlap(args.host_pa, args.size, r.host_pa, r.size))
        {
            return sbi_core.setResult(
                vc,
                ctx,
                sbi_core.SBI_ERR_ALREADY_AVAILABLE,
                0,
            );
        }
    }
    const slot = free_slot orelse
        return sbi_core.setResult(vc, ctx, sbi_core.SBI_ERR_FAILED, 0);

    child.space.mapPassthroughMmio(
        @intCast(args.child_gpa),
        @intCast(args.host_pa),
        @intCast(args.size),
        is_ro,
    ) catch |err| {
        const sbi_err = if (err == error.MappingOverlap)
            sbi_core.SBI_ERR_ALREADY_AVAILABLE
        else
            sbi_core.SBI_ERR_FAILED;
        return sbi_core.setResult(vc, ctx, sbi_err, 0);
    };

    slot.* = .{
        .active = true,
        .guest_id = child.id,
        .host_pa = args.host_pa,
        .child_gpa = args.child_gpa,
        .size = args.size,
        .read_only = is_ro,
    };
    sbi_core.setResult(vc, ctx, sbi_core.SBI_SUCCESS, 0);
}

pub fn releaseAllForGuest(g: *guest_mod.Guest) void {
    plic.releaseGuestIrqs(g.id);

    var unmap_list: [MAX_MAPPED_MMIO_REGIONS]MappedMmioRegion = @splat(.{});
    var unmap_count: usize = 0;
    {
        const s = mmio_lock.lock();
        defer mmio_lock.unlock(s);
        for (&mmio_regions) |*r| {
            if (r.active and r.guest_id == g.id) {
                unmap_list[unmap_count] = r.*;
                unmap_count += 1;
                r.* = .{};
            }
        }
    }

    for (unmap_list[0..unmap_count]) |r| {
        g.space.unmap(@intCast(r.child_gpa), @intCast(r.size));
    }
    if (unmap_count > 0 and riscv.hasHExtension()) riscv.hfenceGvma();
}

test "passthrough: DMA-trust gate, exclusions, QUERY_RAM, and reuse" {
    _ = plic;
    const testing = std.testing;
    const alloc = testing.allocator;
    resetForTest();
    defer resetForTest();
    riscv.initMockHardware();

    var phys_test = try physmem.initForTest(alloc, 256);
    defer phys_test.deinit();

    const parent = try guest_mod.createGuest(
        alloc,
        true,
        true,
        null,
        0,
        0,
        0,
        .riscv64,
    );
    defer parent.deinit();
    const p_page = try physmem.allocPage();
    try parent.space.map(
        0x8000_0000,
        p_page,
        physmem.PageSize,
        sv39x4.PTEFlags.leaf_rw_user,
    );
    physmem.decrementPageRef(p_page);

    var pvc = vcore.VirtualCore.init(0, parent, 0x8000_0000, 0, .normal);
    var tctx: riscv.ThreadContext = @splat(0);
    const child = try parent.createChild(false, .riscv64, 1);
    defer child.deinit();
    parent.quotas.max_ram_pages = 256;

    var bad_args = interface.MapChildMmioArgs{
        .child_id = child.local_cid,
        .host_pa = 0x8000_0000,
        .child_gpa = 0x3000_0000,
        .size = 0x1000,
        .flags = interface.MmioPassFlags.READ_ONLY,
    };
    try parent.space.writeGuestStruct(
        interface.MapChildMmioArgs,
        0x8000_0000,
        bad_args,
    );
    handleMapChildMmio(&pvc, &tctx, 0x8000_0000);
    const denied: usize = @bitCast(sbi_core.SBI_ERR_DENIED);
    try testing.expectEqual(denied, tctx[sbi_core.A0_REG]);

    var mmio_args = interface.MapChildMmioArgs{
        .child_id = child.local_cid,
        .host_pa = 0x3000_0000,
        .child_gpa = 0x3000_0000,
        .size = 0x2000,
        .flags = 0,
    };
    try parent.space.writeGuestStruct(
        interface.MapChildMmioArgs,
        0x8000_0000,
        mmio_args,
    );
    handleMapChildMmio(&pvc, &tctx, 0x8000_0000);
    try testing.expectEqual(denied, tctx[sbi_core.A0_REG]);

    mmio_args.flags = interface.MmioPassFlags.READ_ONLY;
    try parent.space.writeGuestStruct(
        interface.MapChildMmioArgs,
        0x8000_0000,
        mmio_args,
    );
    handleMapChildMmio(&pvc, &tctx, 0x8000_0000);
    try testing.expectEqual(@as(usize, 0), tctx[sbi_core.A0_REG]);

    bad_args = .{
        .child_id = child.local_cid,
        .host_pa = 0x5000_0000,
        .child_gpa = VIRT_PLIC_BASE,
        .size = 0x1000,
        .flags = interface.MmioPassFlags.READ_ONLY,
    };
    try parent.space.writeGuestStruct(
        interface.MapChildMmioArgs,
        0x8000_0000,
        bad_args,
    );
    handleMapChildMmio(&pvc, &tctx, 0x8000_0000);
    try testing.expectEqual(denied, tctx[sbi_core.A0_REG]);

    child.is_dma_trusted = true;
    try parent.setQuota(.{
        .target_cid = child.local_cid,
        .max_ram_pages = 4,
    });
    mmio_args = .{
        .child_id = child.local_cid,
        .flags = interface.MmioPassFlags.QUERY_RAM,
    };
    try parent.space.writeGuestStruct(
        interface.MapChildMmioArgs,
        0x8000_0000,
        mmio_args,
    );
    handleMapChildMmio(&pvc, &tctx, 0x8000_0000);
    try testing.expectEqual(@as(usize, 0), tctx[sbi_core.A0_REG]);
    const q = try parent.space.readGuestStruct(
        interface.MapChildMmioArgs,
        0x8000_0000,
    );
    try testing.expect(q.host_pa != 0);
    if (q.host_pa + q.size <= sv39x4.MAX_GPA) {
        try testing.expectEqual(q.child_gpa, q.host_pa);
    } else {
        try testing.expectEqual(@as(u64, 0x8000_0000), q.child_gpa);
    }
    try testing.expectEqual(@as(u64, 4 * physmem.PageSize), q.size);

    mmio_args = .{
        .child_id = child.local_cid,
        .host_pa = 0x4000_0000,
        .child_gpa = 0x4000_0000,
        .size = 0x2000,
        .flags = interface.MmioPassFlags.DMA_TRUSTED,
    };
    try parent.space.writeGuestStruct(
        interface.MapChildMmioArgs,
        0x8000_0000,
        mmio_args,
    );
    handleMapChildMmio(&pvc, &tctx, 0x8000_0000);
    try testing.expectEqual(@as(usize, 0), tctx[sbi_core.A0_REG]);

    const child2 = try parent.createChild(false, .riscv64, 1);
    defer child2.deinit();
    child2.is_dma_trusted = true;
    mmio_args.child_id = child2.local_cid;
    try parent.space.writeGuestStruct(
        interface.MapChildMmioArgs,
        0x8000_0000,
        mmio_args,
    );
    handleMapChildMmio(&pvc, &tctx, 0x8000_0000);
    const busy: usize = @bitCast(sbi_core.SBI_ERR_ALREADY_AVAILABLE);
    try testing.expectEqual(busy, tctx[sbi_core.A0_REG]);

    releaseAllForGuest(child);
    try parent.space.writeGuestStruct(
        interface.MapChildMmioArgs,
        0x8000_0000,
        mmio_args,
    );
    handleMapChildMmio(&pvc, &tctx, 0x8000_0000);
    try testing.expectEqual(@as(usize, 0), tctx[sbi_core.A0_REG]);
}
