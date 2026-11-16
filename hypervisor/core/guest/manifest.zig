// Guest VM manifest storage and execution lifecycle state helpers.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const physmem = @import("../physmem.zig");
const scheduler = @import("../scheduler.zig");
const guest_mod = @import("../guest.zig");
const vcore = @import("../vcore.zig");
const sbi = @import("interface").sbi;
const pcore = @import("../pcore.zig");
const emulation = @import("emulation");
const quota_mod = @import("quota.zig");
pub const net_mod = @import("net.zig");

pub const MAX_STOP_SPINS: usize = 10_000_000;
pub const STOP_IPI_RETRY_SPINS: usize = 1024;
pub const NetPort = net_mod.NetPort;
pub const deliverToChildUpstream = net_mod.deliverToChildUpstream;
pub const deliverToParentDownstream = net_mod.deliverToParentDownstream;
pub const routeEthernetFrameOnPort = net_mod.routeEthernetFrameOnPort;
pub const routeEthernetFrame = net_mod.routeEthernetFrame;
pub const onVirtioNetTx = net_mod.onVirtioNetTx;

fn ensureGuestDramRangeMapped(
    g: *guest_mod.Guest,
    addr: usize,
    len: usize,
) bool {
    if (len == 0 or g.space.mode != .h_paging or g.space.base_hpa != 0) {
        return true;
    }
    const end = std.math.add(usize, addr, len) catch return false;
    var page_gpa = std.mem.alignBackward(usize, addr, physmem.PageSize);
    while (page_gpa < end) {
        if ((g.space.translateGPA(page_gpa) catch null) == null) {
            if (g.space.range_size == 0 or page_gpa < g.space.base_gpa or
                (page_gpa - g.space.base_gpa) >= g.space.range_size)
            {
                return false;
            }
            if (!g.checkRamQuota(1)) return false;
            const mapped_new = g.space.handleFault(
                @ptrCast(g),
                page_gpa,
                0,
            ) catch return false;
            if (mapped_new) g.consumeQuota(1, 0);
            if (!builtin.is_test) pcore.this().gstage_dirty = true;
        }
        page_gpa = std.math.add(usize, page_gpa, physmem.PageSize) catch break;
    }
    return true;
}

pub fn guestReadMemory(ctx: *anyopaque, gpa: u64, buf: []u8) bool {
    const g: *guest_mod.Guest = @ptrCast(@alignCast(ctx));
    const addr: usize = std.math.cast(usize, gpa) orelse return false;
    if (!ensureGuestDramRangeMapped(g, addr, buf.len)) return false;
    g.space.copyFromGuest(buf, addr) catch return false;
    return true;
}

pub fn guestWriteMemory(ctx: *anyopaque, gpa: u64, buf: []const u8) bool {
    const g: *guest_mod.Guest = @ptrCast(@alignCast(ctx));
    const addr: usize = std.math.cast(usize, gpa) orelse return false;
    if (!ensureGuestDramRangeMapped(g, addr, buf.len)) return false;
    g.space.copyToGuest(addr, buf) catch return false;
    return true;
}

pub fn initVirtualDevices(self: *guest_mod.Guest) void {
    const mem = emulation.MemoryAccessor{
        .ctx = self,
        .readFn = guestReadMemory,
        .writeFn = guestWriteMemory,
    };
    self.vsock = emulation.VirtioVsock{
        .guest_cid = self.local_cid,
        .mem = mem,
        .router = emulation.global_vsock_router,
        .route_fn = guest_mod.lineage_mod.routeVsockPacket,
    };
    emulation.global_vsock_router.register(&self.vsock);
    self.gpu = emulation.VirtioGpu.initWithMem(
        self.local_cid,
        mem,
        self.allocator,
    );
    self.input = emulation.VirtioInput.initWithMem(self.local_cid, mem);
    self.blk = emulation.VirtioBlk.init(self.space.base_gpa, mem);
    self.net_dev = emulation.VirtioNet.init(self.local_cid, mem);
    self.net_dev.tx_ctx = self;
    self.net_dev.tx_fn = onVirtioNetTx;
}

pub fn setManifest(self: *guest_mod.Guest, data: []const u8) !void {
    if (data.len > guest_mod.MAX_MANIFEST_SIZE_BYTES) {
        return error.ManifestTooLarge;
    }
    const new_buf = try self.allocator.alloc(u8, data.len);
    @memcpy(new_buf, data);
    const old_buf = blk: {
        const s = self.manifest_lock.lock();
        defer self.manifest_lock.unlock(s);
        const old = self.manifest;
        self.manifest = new_buf;
        break :blk old;
    };
    if (old_buf) |m| self.allocator.free(m);
}

pub fn readManifest(self: *guest_mod.Guest, out_buf: []u8) ?usize {
    const s = self.manifest_lock.lock();
    defer self.manifest_lock.unlock(s);
    if (self.manifest) |m| {
        const copy_len: usize = @min(out_buf.len, m.len);
        @memcpy(out_buf[0..copy_len], m[0..copy_len]);
        return m.len;
    }
    return null;
}

pub fn getManifestLength(self: *guest_mod.Guest) usize {
    const s = self.manifest_lock.lock();
    defer self.manifest_lock.unlock(s);
    return if (self.manifest) |m| m.len else 0;
}

pub fn hasAnyVcoreStarted(self: *const guest_mod.Guest) bool {
    if (self.initial_entry_point != 0) return true;
    var it = self.vcores.start;
    while (it) |node| : (it = node.next) {
        const vc = node.contents;
        if (vc.state != .stopped or vc.last_queued_time != 0 or
            vc.last_dispatched_time != 0) return true;
    }
    return false;
}

pub fn stop(self: *guest_mod.Guest) void {
    const riscv = @import("../../hardware/native/cpu/riscv64/mod.zig");
    const my_cpu = if (builtin.is_test)
        0
    else
        riscv.getCPUContext().cpu_core_id;
    var it = self.vcores.start;
    while (it) |node| : (it = node.next) {
        const vc = node.contents;
        @atomicStore(vcore.VirtualCoreState, &vc.state, .stopped, .seq_cst);
        if (@atomicLoad(bool, &vc.wfi_blocked, .acquire)) {
            _ = vc.tryWake();
        }
        @atomicStore(vcore.VirtualCoreState, &vc.state, .stopped, .seq_cst);
        @atomicStore(bool, &vc.wfi_blocked, false, .release);
        scheduler.dequeue(vc);
        if (!builtin.is_test) {
            if (vc.getRunningCpu()) |home_cpu| {
                if (home_cpu != my_cpu) pcore.sendIpiToCpu(home_cpu);
            }
        }
    }

    if (!builtin.is_test) {
        it = self.vcores.start;
        while (it) |node| : (it = node.next) {
            const vc = node.contents;
            var spins: usize = 0;
            while (vc.getRunningCpu()) |cur_cpu| {
                if (cur_cpu == my_cpu or spins >= MAX_STOP_SPINS) break;
                if (spins % STOP_IPI_RETRY_SPINS == 0) {
                    pcore.sendIpiToCpu(cur_cpu);
                }
                spins += 1;
                std.atomic.spinLoopHint();
            }
        }
    }
}

pub fn resetForRun(self: *guest_mod.Guest, entry: usize, dtb: usize) void {
    self.state = .valid;
    self.initial_entry_point = entry;
    self.initial_dtb_ptr = dtb;
    self.uart = .{
        .guest_id = self.id,
        .out_ctx = self,
        .out_ctx_fn = guest_mod.Guest.guestUartOutputCtx,
        .in_ctx_fn = guest_mod.Guest.guestUartInputCtx,
        .peek_in_ctx_fn = guest_mod.Guest.guestUartHasInputCtx,
    };
    self.console_rx.clear();
    self.gpu.reset();
    self.input.reset();
    self.timer.reset();
    self.pic.reset();
    var is_primary = true;
    var it = self.vcores.start;
    while (it) |node| : (it = node.next) {
        const vc = node.contents;
        vc.reset(entry, dtb);
        vc.state = if (is_primary) .ready else .stopped;
        is_primary = false;
    }
}

test "guest quota management, H-mode OOM, PMP, manifest, and VMID guard" {
    _ = net_mod;
    std.testing.refAllDecls(@This());
    const testing = std.testing;
    const allocator = testing.allocator;

    scheduler.init();
    scheduler.initCpu();
    quota_mod.resetGuestManagerForTest();

    var phys_test = try physmem.initForTest(allocator, 4096);
    defer phys_test.deinit();

    const parent = try guest_mod.createGuest(
        allocator,
        true,
        true,
        null,
        0,
        0,
        0x1000000,
        .riscv64,
    );
    defer parent.deinit();
    parent.quotas.max_ram_pages = 3072;
    _ = try parent.addVcore(0, 0, 0, .normal, null);

    const child = try parent.createChild(false, .riscv64, 1);
    defer child.deinit();

    // 1. Grant child 1 80% pCPU and 1024 pages RAM quota with 2048 pages
    // logical RAM (H-mode overprovisioning).
    try parent.setQuota(.{
        .target_cid = 2,
        .max_ram_pages = 1024,
        .max_vcpus = 2,
        .max_child_depth = 4,
        .max_descendants = 10,
        .pcpu_quota_pct = 80,
        .logical_ram_pages = 2048,
    });
    try testing.expectEqual(@as(usize, 1024), child.quotas.max_ram_pages);
    try testing.expectEqual(@as(usize, 2), child.quotas.max_vcpus);
    try testing.expectEqual(@as(u32, 80), child.quotas.pcpu_quota_pct);
    try testing.expectEqual(@as(u32, 80), parent.quotas.delegated_pcpu_pct);
    try testing.expectEqual(
        @as(usize, 1024),
        parent.quotas.delegated_ram_pages,
    );
    try testing.expectEqual(
        @as(usize, 2048 * physmem.PageSize),
        child.space.range_size,
    );

    // Exceeding 90% pCPU cap on a child is denied.
    try testing.expectError(
        error.AccessDenied,
        parent.setQuota(.{
            .target_cid = 2,
            .max_ram_pages = 1024,
            .pcpu_quota_pct = 95,
        }),
    );

    // 2. Dial child 1 down to 50% pCPU, freeing 40% for another child.
    try parent.setQuota(.{
        .target_cid = 2,
        .max_ram_pages = 1024,
        .pcpu_quota_pct = 50,
    });
    try testing.expectEqual(@as(u32, 50), parent.quotas.delegated_pcpu_pct);

    try child.setQuota(.{
        .target_cid = sbi.CID_SELF,
        .max_ram_pages = 512,
        .max_vcpus = 1,
        .max_child_depth = 2,
        .max_descendants = 5,
    });
    try testing.expectEqual(@as(usize, 512), child.quotas.max_ram_pages);
    try testing.expectEqual(@as(usize, 1), child.quotas.max_vcpus);

    try testing.expectError(
        error.AccessDenied,
        child.setQuota(.{
            .target_cid = sbi.CID_PARENT,
            .max_ram_pages = 100,
            .max_vcpus = 1,
            .max_child_depth = 1,
            .max_descendants = 1,
        }),
    );

    const sample_manifest = "[vm]\nname = \"test-child\"\ncid = 2\n";
    try child.setManifest(sample_manifest);
    var read_buf: [64]u8 = undefined;
    const mlen = child.readManifest(&read_buf).?;
    try testing.expectEqualStrings(sample_manifest, read_buf[0..mlen]);

    try testing.expect(!child.checkQuota(std.math.maxInt(usize), 1, 1));
    try testing.expect(!child.checkQuota(1, std.math.maxInt(usize), 1));

    const parent_base_ram = parent.quotas.used_ram_pages;
    try testing.expect(child.checkRamQuota(100));
    try testing.expect(!child.checkRamQuota(600));
    child.consumeQuota(100, 0);
    try testing.expectEqual(@as(usize, 100), child.quotas.used_ram_pages);
    const exp_ram = parent_base_ram + 100;
    try testing.expectEqual(exp_ram, parent.quotas.used_ram_pages);

    // 3. Dialing child's RAM quota below in-use memory (100 pages -> 64 pages)
    // triggers child_memory_pressure event and OOM termination.
    try parent.setQuota(.{
        .target_cid = 2,
        .max_ram_pages = 64,
    });
    try testing.expectEqual(guest_mod.GuestLifecycleState.dying, child.state);
    const ev = parent.events.pop().?;
    try testing.expectEqual(
        @backingInt(sbi.EventType.child_memory_pressure),
        ev.event_type,
    );
    child.releaseQuota(100, 0);

    // 4. PMP-based child fails immediately on creation if logical RAM > quota.
    const pmp_child = try parent.createChild(false, .riscv64, 1);
    defer pmp_child.deinit();
    pmp_child.space.mode = .pmp_fallback;
    try testing.expectError(
        error.AccessDenied,
        parent.setQuota(.{
            .target_cid = pmp_child.local_cid,
            .max_ram_pages = 512,
            .logical_ram_pages = 1024,
        }),
    );
    pmp_child.terminateWithCode(0);

    // 5. VMID double-free guard: terminateWithCode followed by deinit.
    const child1 = try parent.createChild(false, .riscv64, 0);
    const vmid1 = child1.vmid;
    try testing.expect(vmid1 != 0);
    child1.terminateWithCode(0);
    try testing.expectEqual(@as(u16, 0), child1.vmid);

    const child2 = try parent.createChild(false, .riscv64, 0);
    defer child2.deinit();
    try testing.expectEqual(vmid1, child2.vmid);

    child1.deinit();
    try testing.expect(quota_mod.isVmidAllocated(child2.vmid));

    // 6. VirtIO DMA write/read to unmapped demand-paged child DRAM allocates
    // and accounts physical pages within guest RAM bounds.
    child2.space.base_gpa = 0xe000_0000;
    child2.space.range_size = 0x0040_0000;
    if (child2.space.paging) |*pt| {
        pt.root_base_gpa = 0xe000_0000;
        pt.root_range_size = 0x0040_0000;
    }
    const used_before = child2.quotas.used_ram_pages;
    try testing.expect(guestWriteMemory(child2, 0xe001_0000, "DMA-DEMAND-OK"));
    try testing.expectEqual(used_before + 1, child2.quotas.used_ram_pages);
    var dma_out: [13]u8 = undefined;
    try testing.expect(guestReadMemory(child2, 0xe001_0000, &dma_out));
    try testing.expectEqualStrings("DMA-DEMAND-OK", &dma_out);
    try testing.expect(!guestWriteMemory(child2, 0xe080_0000, "OOB"));
}
