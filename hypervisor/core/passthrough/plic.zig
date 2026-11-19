// Physical PLIC External IRQ Delegation & End-of-Interrupt Forwarding.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const atomic = @import("../atomic.zig");
const guest_mod = @import("../guest.zig");
const vcore = @import("../vcore.zig");
const pcore = @import("../pcore.zig");
const scheduler = @import("../scheduler.zig");
const riscv = @import("../../hardware/native/cpu/riscv64/mod.zig");
const physmem = @import("../physmem.zig");
const sv39x4 = @import("../../hardware/native/cpu/riscv64/sv39x4.zig");
const interface = @import("interface").sbi;
const sbi_core = @import("../sbi.zig");

pub const MAX_DELEGATED_IRQS: usize = interface.MAX_DELEGATED_IRQS;
pub const PLIC_MAX_PHYS_IRQS: u32 = 1024;
pub const PLIC_MAX_VIRT_IRQS: u32 = 128;
pub const MIN_DELEGATABLE_VIRT_IRQ: u32 = 16;

const PLIC_PRIORITY_BASE: usize = 0x000000;
const PLIC_ENABLE_BASE: usize = 0x002000;
const PLIC_ENABLE_CTX_STRIDE: usize = 0x80;
const PLIC_CONTEXT_BASE: usize = 0x200000;
const PLIC_CONTEXT_STRIDE: usize = 0x1000;
const PLIC_CONTEXT_OFFSET_MASK: u32 = 0xfff;
const PLIC_REG_THRESHOLD: usize = 0x0;
const PLIC_REG_CLAIM_COMPLETE: usize = 0x4;

const VIRT_PLIC_BASE: u32 = 0x0c00_0000;
const VIRT_PLIC_SIZE: u32 = 0x0400_0000;

pub var test_plic_base: ?usize = null;
var plic_lock = atomic.SpinLock.init();
var active_count = std.atomic.Value(usize).init(0);

const DelegatedIrq = struct {
    active: bool = false,
    in_flight: bool = false,
    guest: ?*guest_mod.Guest = null,
    guest_id: usize = 0,
    phys_irq: u32 = 0,
    virt_irq: u32 = 0,
    m_ctx: u32 = 0,
};

var delegated_irqs: [MAX_DELEGATED_IRQS]DelegatedIrq = @splat(.{});

pub const ExtIrqResult = struct {
    handled: bool,
    woke_child: bool,
};

pub fn hasActiveDelegatedIrqs() bool {
    return active_count.load(.acquire) > 0;
}

pub fn resetForTest() void {
    const s = plic_lock.lock();
    defer plic_lock.unlock(s);
    delegated_irqs = @splat(.{});
    active_count.store(0, .release);
    test_plic_base = null;
}

pub fn getPlicBase() ?usize {
    return test_plic_base orelse riscv.plic_base;
}

fn getHandlerBootHartId() usize {
    if (pcore.fromId(0)) |p0| return p0.hardware_hart_id;
    return riscv.getCPUContext().hardware_hart_id;
}

fn plicRegPtr(base: usize, offset: usize) *volatile u32 {
    return @ptrFromInt(base + offset);
}

fn plicEnableOff(ctx: u32, irq: u32) usize {
    const word = irq / 32;
    return PLIC_ENABLE_BASE +
        (@as(usize, ctx) * PLIC_ENABLE_CTX_STRIDE) +
        (@as(usize, word) * @sizeOf(u32));
}

fn plicClaimOff(ctx: u32) usize {
    return PLIC_CONTEXT_BASE +
        (@as(usize, ctx) * PLIC_CONTEXT_STRIDE) +
        PLIC_REG_CLAIM_COMPLETE;
}

fn configurePlicIrqLocked(base: usize, m_ctx: u32, phys_irq: u32) void {
    const bit: u5 = @truncate(phys_irq % 32);
    const mask: u32 = @as(u32, 1) << bit;
    const prio_ptr = plicRegPtr(
        base,
        PLIC_PRIORITY_BASE + (@as(usize, phys_irq) * @sizeOf(u32)),
    );
    if (prio_ptr.* == 0) prio_ptr.* = 1;

    // Ensure Root VM S-mode PLIC contexts cannot double-claim this IRQ.
    const s_limit: u32 = @min(32, riscv.getOnlineCpuCount() * 2 + 2);
    var s_ctx: u32 = 1;
    while (s_ctx < s_limit) : (s_ctx += 2) {
        const s_en = plicRegPtr(base, plicEnableOff(s_ctx, phys_irq));
        s_en.* &= ~mask;
    }

    const thresh_off = PLIC_CONTEXT_BASE +
        (@as(usize, m_ctx) * PLIC_CONTEXT_STRIDE) +
        PLIC_REG_THRESHOLD;
    plicRegPtr(base, thresh_off).* = 0;

    const m_en = plicRegPtr(base, plicEnableOff(m_ctx, phys_irq));
    m_en.* |= mask;
}

fn releasePlicIrqLocked(entry: *DelegatedIrq) void {
    if (getPlicBase()) |base| {
        const bit: u5 = @truncate(entry.phys_irq % 32);
        const mask: u32 = @as(u32, 1) << bit;
        const m_en = plicRegPtr(base, plicEnableOff(entry.m_ctx, entry.phys_irq));
        m_en.* &= ~mask;
        if (entry.in_flight) {
            plicRegPtr(base, plicClaimOff(entry.m_ctx)).* = entry.phys_irq;
        }
    }
    entry.* = .{};
}

fn updateDelegatedCountLocked() void {
    var n: usize = 0;
    for (&delegated_irqs) |*e| {
        if (e.active) n += 1;
    }
    active_count.store(n, .release);
}

pub fn handleDelegateChildIrq(
    vc: *vcore.VirtualCore,
    ctx: *riscv.ThreadContext,
    args_gpa: usize,
) void {
    const parent = vc.getGuest();
    if (!parent.is_trusted and !parent.has_host_passthrough) {
        return sbi_core.setResult(vc, ctx, sbi_core.SBI_ERR_DENIED, 0);
    }
    const F = interface.IrqPassFlags;
    var args = parent.space.readGuestStruct(
        interface.DelegateChildIrqArgs,
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
    if (child.target_arch != .riscv64 or child.space.mode != .h_paging) {
        return sbi_core.setResult(vc, ctx, sbi_core.SBI_ERR_NOT_SUPPORTED, 0);
    }
    if (args.phys_irq == 0 or args.phys_irq >= PLIC_MAX_PHYS_IRQS) {
        return sbi_core.setResult(vc, ctx, sbi_core.SBI_ERR_INVALID_PARAM, 0);
    }

    const s = plic_lock.lock();
    defer plic_lock.unlock(s);

    if ((args.flags & F.RELEASE) != 0) {
        for (&delegated_irqs) |*e| {
            if (e.active and e.guest_id == child.id and
                e.phys_irq == args.phys_irq)
            {
                releasePlicIrqLocked(e);
                updateDelegatedCountLocked();
                return sbi_core.setResult(vc, ctx, sbi_core.SBI_SUCCESS, 0);
            }
        }
        return sbi_core.setResult(vc, ctx, sbi_core.SBI_ERR_INVALID_PARAM, 0);
    }

    const virt_irq = if (args.virt_irq == 0) args.phys_irq else args.virt_irq;
    if (virt_irq < MIN_DELEGATABLE_VIRT_IRQ or virt_irq >= PLIC_MAX_VIRT_IRQS) {
        return sbi_core.setResult(vc, ctx, sbi_core.SBI_ERR_INVALID_PARAM, 0);
    }

    var free_slot: ?*DelegatedIrq = null;
    for (&delegated_irqs) |*e| {
        if (!e.active) {
            if (free_slot == null) free_slot = e;
            continue;
        }
        if (e.phys_irq == args.phys_irq and e.guest_id != child.id) {
            return sbi_core.setResult(
                vc,
                ctx,
                sbi_core.SBI_ERR_ALREADY_AVAILABLE,
                0,
            );
        }
        if (e.guest_id == child.id and e.phys_irq == args.phys_irq) {
            free_slot = e;
        } else if (e.guest_id == child.id and e.virt_irq == virt_irq) {
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

    const m_ctx: u32 = @truncate(getHandlerBootHartId() * 2);
    if (getPlicBase()) |base| configurePlicIrqLocked(base, m_ctx, args.phys_irq);
    slot.* = .{
        .active = true,
        .in_flight = false,
        .guest = child,
        .guest_id = child.id,
        .phys_irq = args.phys_irq,
        .virt_irq = virt_irq,
        .m_ctx = m_ctx,
    };
    updateDelegatedCountLocked();

    args.virt_irq = virt_irq;
    parent.space.writeGuestStruct(
        interface.DelegateChildIrqArgs,
        args_gpa,
        args,
    ) catch return sbi_core.setResult(
        vc,
        ctx,
        sbi_core.SBI_ERR_INVALID_ADDRESS,
        0,
    );
    sbi_core.setResult(vc, ctx, sbi_core.SBI_SUCCESS, virt_irq);
}

fn injectGuestExternalIrq(pcpu: *riscv.CpuContext, g: *guest_mod.Guest) bool {
    var woke = false;
    var it = g.vcores.start;
    while (it) |node| : (it = node.next) {
        const tvc = node.contents;
        if (tvc.getState() == .stopped) continue;
        if (!g.pic.hasDeliverableIrqForHart(tvc.id)) continue;

        tvc.getNativeMachine().hvip |= riscv.HVIP.VSEIP;
        if (pcpu.active_vcore) |opaque_vc| {
            const active_vc: *vcore.VirtualCore =
                @ptrCast(@alignCast(opaque_vc));
            if (active_vc == tvc and riscv.hasHExtension()) {
                riscv.writeHvip(tvc.getNativeMachine().hvip);
            }
        }
        if (tvc.tryWake()) {
            tvc.setBlockedCpu(null);
            scheduler.queue(tvc);
            woke = true;
        } else if (tvc.getRunningCpu()) |cpu| {
            if (cpu != pcpu.cpu_core_id) pcore.sendIpiToCpu(cpu);
        }
    }
    if (woke and !builtin.is_test) pcore.wakeIdleCores();
    return woke;
}

pub fn handleMachineExternalIrq(pcpu: *riscv.CpuContext) ExtIrqResult {
    const base = getPlicBase() orelse
        return .{ .handled = false, .woke_child = false };
    if (!hasActiveDelegatedIrqs())
        return .{ .handled = false, .woke_child = false };

    const m_ctx: u32 = @truncate(pcpu.hardware_hart_id * 2);
    var handled = false;
    var woke_child = false;

    var iter: usize = 0;
    while (iter < PLIC_MAX_PHYS_IRQS) : (iter += 1) {
        const claim_ptr = plicRegPtr(base, plicClaimOff(m_ctx));
        const phys_irq = claim_ptr.*;
        if (phys_irq == 0) break;
        if (test_plic_base != null) claim_ptr.* = 0;
        handled = true;

        var matched_guest: ?*guest_mod.Guest = null;
        var matched_virt: u32 = 0;
        {
            const s = plic_lock.lock();
            defer plic_lock.unlock(s);
            for (&delegated_irqs) |*e| {
                if (e.active and e.m_ctx == m_ctx and e.phys_irq == phys_irq) {
                    if (e.guest) |g| {
                        if (g.state == .valid) {
                            e.in_flight = true;
                            matched_guest = g;
                            matched_virt = e.virt_irq;
                        }
                    }
                    break;
                }
            }
        }

        if (matched_guest) |g| {
            g.pic.setPending(matched_virt);
            if (injectGuestExternalIrq(pcpu, g)) woke_child = true;
        } else {
            plicRegPtr(base, plicClaimOff(m_ctx)).* = phys_irq;
        }
    }
    return .{ .handled = handled, .woke_child = woke_child };
}

pub fn maybeNotifyGuestPlicWrite(
    g: *guest_mod.Guest,
    gpa: u32,
    written_val: u32,
) void {
    if (g.has_host_passthrough or written_val == 0) return;
    if (gpa < VIRT_PLIC_BASE or gpa >= VIRT_PLIC_BASE + VIRT_PLIC_SIZE) return;
    const off = gpa - VIRT_PLIC_BASE;
    if (off < PLIC_CONTEXT_BASE) return;
    if (((off - PLIC_CONTEXT_BASE) & PLIC_CONTEXT_OFFSET_MASK) !=
        PLIC_REG_CLAIM_COMPLETE) return;

    const s = plic_lock.lock();
    defer plic_lock.unlock(s);
    const base = getPlicBase();
    for (&delegated_irqs) |*e| {
        if (e.active and e.guest_id == g.id and e.virt_irq == written_val and
            e.in_flight)
        {
            e.in_flight = false;
            if (base) |b| plicRegPtr(b, plicClaimOff(e.m_ctx)).* = e.phys_irq;
        }
    }
}

pub fn releaseGuestIrqs(guest_id: usize) void {
    const s = plic_lock.lock();
    defer plic_lock.unlock(s);
    for (&delegated_irqs) |*e| {
        if (e.active and e.guest_id == guest_id) releasePlicIrqLocked(e);
    }
    updateDelegatedCountLocked();
}

test "passthrough plic: claim, VSEIP injection, EOI, and exclusive release" {
    const testing = std.testing;
    const alloc = testing.allocator;
    resetForTest();
    defer resetForTest();
    riscv.initMockHardware();

    var phys_test = try physmem.initForTest(alloc, 128);
    defer phys_test.deinit();

    const plic_mem = try alloc.alignedAlloc(u8, .@"4", 0x21_0000);
    defer alloc.free(plic_mem);
    @memset(plic_mem, 0);
    test_plic_base = @intFromPtr(plic_mem.ptr);

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
    const child2 = try parent.createChild(false, .riscv64, 1);
    defer child2.deinit();

    var irq_args = interface.DelegateChildIrqArgs{
        .child_id = child.local_cid,
        .phys_irq = 32,
        .virt_irq = 0,
    };
    try parent.space.writeGuestStruct(
        interface.DelegateChildIrqArgs,
        0x8000_0000,
        irq_args,
    );
    handleDelegateChildIrq(&pvc, &tctx, 0x8000_0000);
    try testing.expectEqual(@as(usize, 0), tctx[sbi_core.A0_REG]);
    try testing.expectEqual(@as(usize, 32), tctx[sbi_core.A1_REG]);
    try testing.expect(hasActiveDelegatedIrqs());

    const child_vc = child.findVcore(0).?;
    child_vc.setState(.ready);
    child.pic.write(0x2000 + 1 * 0x80 + 4, 1 << 0);
    child.pic.write(32 * 4, 1);

    const pcpu = riscv.getCPUContext();
    plicRegPtr(test_plic_base.?, plicClaimOff(0)).* = 32;
    const ext = handleMachineExternalIrq(pcpu);
    try testing.expect(ext.handled);
    try testing.expect(
        (child_vc.getNativeMachine().hvip & riscv.HVIP.VSEIP) != 0,
    );
    plicRegPtr(test_plic_base.?, plicClaimOff(0)).* = 0;

    maybeNotifyGuestPlicWrite(child, 0x0c20_1004, 32);
    try testing.expectEqual(
        @as(u32, 32),
        plicRegPtr(test_plic_base.?, plicClaimOff(0)).*,
    );

    irq_args.child_id = child2.local_cid;
    try parent.space.writeGuestStruct(
        interface.DelegateChildIrqArgs,
        0x8000_0000,
        irq_args,
    );
    handleDelegateChildIrq(&pvc, &tctx, 0x8000_0000);
    const busy: usize = @bitCast(sbi_core.SBI_ERR_ALREADY_AVAILABLE);
    try testing.expectEqual(busy, tctx[sbi_core.A0_REG]);

    releaseGuestIrqs(child.id);
    try testing.expect(!hasActiveDelegatedIrqs());
    handleDelegateChildIrq(&pvc, &tctx, 0x8000_0000);
    try testing.expectEqual(@as(usize, 0), tctx[sbi_core.A0_REG]);
}
