// Diosix SBI parent-to-child graphical desktop display and input handlers.
//
// Allows a parent VM (or Root VM) to stream a child guest's active VirtIO-GPU
// 2D scanout into pinned caller pages with zero M-mode heap allocation, and to
// inject batched evdev keyboard, mouse, and tablet events into VirtIO-Input
// while enforcing confidential and Steward isolation boundaries.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const riscv = @import("../../hardware/native/cpu/riscv64/mod.zig");
const sv39x4 = @import("../../hardware/native/cpu/riscv64/sv39x4.zig");
const vcore = @import("../vcore.zig");
const guest = @import("../guest.zig");
const vm_space = @import("../vm.zig");
const physmem = @import("../physmem.zig");
const scheduler = @import("../scheduler.zig");
const pcore = @import("../pcore.zig");
const sbi_core = @import("../sbi.zig");
const emulation = @import("emulation");
const interface = @import("interface").sbi;

const PIXEL_ALIGN_MASK: u32 = @sizeOf(u32) - 1;
const PAGE_OFFSET_MASK: u64 = physmem.PageSize - 1;
const GPA_CACHE_LEN: usize = 32;

pub fn canAccessGuestDesktop(
    caller: *const guest.Guest,
    target: *const guest.Guest,
) bool {
    if (target == caller) return false;
    if (target.parent != caller) return false;
    if (target.is_confidential or target.is_steward) return false;
    return true;
}

pub fn notifyTargetVcoresIrq(target: *guest.Guest) void {
    var it = target.vcores.start;
    while (it) |node| : (it = node.next) {
        const child_vc = node.contents;
        if (child_vc.tryWake()) {
            scheduler.queue(child_vc);
            pcore.wakeIdleCores();
        } else if (child_vc.getRunningCpu()) |cpu_id| {
            pcore.dispatch.sendIpiToCpu(cpu_id);
        }
    }
}

const PagedGuestSink = struct {
    caller_space: *vm_space.GuestSpace,
    gpa_list_base: usize,
    page_count: usize,
    cur_page_idx: usize = 0,
    cur_page_off: usize,
    cached_base_idx: usize = 0,
    cached_len: usize = 0,
    cached_gpas: [GPA_CACHE_LEN]u64 = @splat(0),
    had_addr_err: bool = false,

    fn ensureCachedPage(self: *PagedGuestSink) ?usize {
        if (self.cur_page_idx >= self.page_count) {
            self.had_addr_err = true;
            return null;
        }
        if (self.cur_page_idx < self.cached_base_idx or
            self.cur_page_idx >= self.cached_base_idx + self.cached_len)
        {
            const n: usize = @min(
                self.page_count - self.cur_page_idx,
                GPA_CACHE_LEN,
            );
            const list_off = self.cur_page_idx * @sizeOf(u64);
            self.caller_space.copyFromGuest(
                std.mem.sliceAsBytes(self.cached_gpas[0..n]),
                self.gpa_list_base + list_off,
            ) catch {
                self.had_addr_err = true;
                return null;
            };
            for (self.cached_gpas[0..n]) |raw_gpa| {
                if ((raw_gpa & PAGE_OFFSET_MASK) != 0) {
                    self.had_addr_err = true;
                    return null;
                }
            }
            self.cached_base_idx = self.cur_page_idx;
            self.cached_len = n;
        }
        return @intCast(
            self.cached_gpas[self.cur_page_idx - self.cached_base_idx],
        );
    }

    fn writePixels(ctx: *anyopaque, pixels: []const u32) bool {
        const self: *PagedGuestSink = @ptrCast(@alignCast(ctx));
        const bytes = std.mem.sliceAsBytes(pixels);
        var pos: usize = 0;
        while (pos < bytes.len) {
            const page_gpa = self.ensureCachedPage() orelse return false;
            const rem_in_page = physmem.PageSize - self.cur_page_off;
            const chunk: usize = @min(bytes.len - pos, rem_in_page);
            self.caller_space.copyToGuest(
                page_gpa + self.cur_page_off,
                bytes[pos .. pos + chunk],
            ) catch {
                self.had_addr_err = true;
                return false;
            };
            pos += chunk;
            self.cur_page_off += chunk;
            if (self.cur_page_off == physmem.PageSize) {
                self.cur_page_off = 0;
                self.cur_page_idx += 1;
            }
        }
        return true;
    }
};

pub fn handleGpuReadScanout(
    vc: *vcore.VirtualCore,
    context: *riscv.ThreadContext,
    g: *guest.Guest,
    a0: usize,
) void {
    var args = g.space.readGuestStruct(interface.GpuScanoutArgs, a0) catch {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
        return;
    };
    if (args.target_cid < guest.CID_FIRST_CHILD) {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_INVALID_PARAM, 0);
        return;
    }
    const target = g.getGuestByCid(@intCast(args.target_cid)) orelse {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_INVALID_PARAM, 0);
        return;
    };
    if (!canAccessGuestDesktop(g, target)) {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_DENIED, 0);
        return;
    }

    if ((args.flags & interface.GpuScanoutFlags.SET_DISPLAY_SIZE) != 0) {
        if (target.gpu.setDisplaySize(args.width, args.height)) {
            target.pic.setPending(emulation.Bus.IRQ_GPU);
            notifyTargetVcoresIrq(target);
        }
    }

    const old_seq = args.frame_seq;
    if (args.pixels_ptr == 0) {
        const snap = target.gpu.streamScanout(old_seq, 0, null);
        const changed = snap.active and snap.frame_seq != old_seq;
        const f_act = if (snap.active) interface.GpuScanoutFlags.ACTIVE else 0;
        const f_upd = if (changed) interface.GpuScanoutFlags.UPDATED else 0;
        args.width = snap.width;
        args.height = snap.height;
        args.frame_seq = snap.frame_seq;
        args.flags = f_act | f_upd;
        g.space.writeGuestStruct(interface.GpuScanoutArgs, a0, args) catch {
            sbi_core.setResult(
                vc,
                context,
                sbi_core.SBI_ERR_INVALID_ADDRESS,
                0,
            );
            return;
        };
        sbi_core.setResult(
            vc,
            context,
            sbi_core.SBI_SUCCESS,
            if (changed) 1 else 0,
        );
        return;
    }

    if (args.page_count == 0 or
        args.page_count > interface.MAX_GPU_SCANOUT_PAGES or
        args.first_page_offset >= physmem.PageSize or
        (args.first_page_offset & PIXEL_ALIGN_MASK) != 0 or
        args.max_pixels == 0)
    {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_INVALID_PARAM, 0);
        return;
    }

    const gpa_list_base: usize = @intCast(args.pixels_ptr);
    const gpa_list_bytes = @as(usize, args.page_count) * @sizeOf(u64);
    _ = std.math.add(usize, gpa_list_base, gpa_list_bytes) catch {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
        return;
    };

    const total_page_bytes = @as(usize, args.page_count) * physmem.PageSize;
    const avail_bytes = total_page_bytes - @as(usize, args.first_page_offset);
    const max_pixels: usize = @min(
        @as(usize, args.max_pixels),
        avail_bytes / @sizeOf(u32),
    );

    var sink = PagedGuestSink{
        .caller_space = &g.space,
        .gpa_list_base = gpa_list_base,
        .page_count = args.page_count,
        .cur_page_off = args.first_page_offset,
    };
    const snap = target.gpu.streamScanout(
        old_seq,
        max_pixels,
        .{ .ctx = &sink, .writeFn = PagedGuestSink.writePixels },
    );
    if (sink.had_addr_err) {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
        return;
    }

    args.width = snap.width;
    args.height = snap.height;
    args.frame_seq = snap.frame_seq;
    args.flags = (if (snap.active) interface.GpuScanoutFlags.ACTIVE else 0) |
        (if (snap.updated) interface.GpuScanoutFlags.UPDATED else 0);
    g.space.writeGuestStruct(interface.GpuScanoutArgs, a0, args) catch {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
        return;
    };
    sbi_core.setResult(
        vc,
        context,
        sbi_core.SBI_SUCCESS,
        if (snap.updated) 1 else 0,
    );
}

pub fn handleInputSendEvent(
    vc: *vcore.VirtualCore,
    context: *riscv.ThreadContext,
    g: *guest.Guest,
    a0: usize,
) void {
    const args = g.space.readGuestStruct(interface.InputEventArgs, a0) catch {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
        return;
    };
    if (args.target_cid < guest.CID_FIRST_CHILD or
        args.count > interface.MAX_INPUT_BATCH_EVENTS)
    {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_INVALID_PARAM, 0);
        return;
    }
    const target = g.getGuestByCid(@intCast(args.target_cid)) orelse {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_INVALID_PARAM, 0);
        return;
    };
    if (!canAccessGuestDesktop(g, target)) {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_DENIED, 0);
        return;
    }
    if (args.count == 0) {
        sbi_core.setResult(vc, context, sbi_core.SBI_SUCCESS, 0);
        return;
    }

    for (args.events[0..args.count]) |ev| {
        _ = target.input.pushEvent(ev.type, ev.code, ev.value);
    }
    target.pic.setPending(emulation.Bus.IRQ_INPUT);
    notifyTargetVcoresIrq(target);
    sbi_core.setResult(vc, context, sbi_core.SBI_SUCCESS, args.count);
}

test "SBI desktop scanout streaming and input batching" {
    std.testing.refAllDecls(@This());
    const testing = std.testing;
    const alloc = testing.allocator;
    const arch = @import("interface").riscv;
    const vgpu = @import("emulation").VirtioGpu;
    const vgpu_proto = vgpu.proto_mod;
    const vgpu_cmds = vgpu.commands_mod;

    scheduler.init();
    scheduler.initCpu();
    var phys_test = try physmem.initForTest(alloc, 256);
    defer phys_test.deinit();

    const parent = try guest.createGuest(
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
    for (0..3) |i| {
        const p = try physmem.allocPage();
        try parent.space.map(
            0x8000_0000 + i * physmem.PageSize,
            p,
            physmem.PageSize,
            sv39x4.PTEFlags.leaf_rw_user,
        );
        physmem.decrementPageRef(p);
    }

    const child = try parent.createChild(false, .riscv64, 1);
    defer child.deinit();
    const c_page = try physmem.allocPage();
    try child.space.map(
        0x8000_0000,
        c_page,
        physmem.PageSize,
        sv39x4.PTEFlags.leaf_rw_user,
    );
    physmem.decrementPageRef(c_page);

    // Configure a 2x2 B8G8R8X8 resource on child GPU at child GPA 0x8000_0100.
    try child.space.copyToGuest(0x8000_0100, &[_]u8{
        0x11, 0x22, 0x33, 0xff,
        0x44, 0x55, 0x66, 0xff,
        0x77, 0x88, 0x99, 0xff,
        0xaa, 0xbb, 0xcc, 0xff,
    });
    _ = vgpu_cmds.handleResourceCreate2DLocked(&child.gpu, &.{
        .hdr = .{},
        .resource_id = 1,
        .format = vgpu_proto.VIRTIO_GPU_FORMAT_B8G8R8X8_UNORM,
        .width = 2,
        .height = 2,
    });
    const ent = [_]vgpu_proto.VirtioGpuMemEntry{
        .{ .addr = 0x8000_0100, .length = 16 },
    };
    _ = vgpu_cmds.handleAttachBackingSliceLocked(
        &child.gpu,
        &.{ .hdr = .{}, .resource_id = 1, .nr_entries = 1 },
        &ent,
    );
    _ = vgpu_cmds.handleSetScanoutLocked(&child.gpu, &.{
        .hdr = .{},
        .r = .{ .x = 0, .y = 0, .width = 2, .height = 2 },
        .scanout_id = 0,
        .resource_id = 1,
    });

    var p_vc = vcore.VirtualCore.init(0, parent, 0x8000_0000, 0, .normal);
    var ctx: riscv.ThreadContext = @splat(0);
    const a0_reg = @backingInt(arch.Register.a0);
    const a1_reg = @backingInt(arch.Register.a1);

    // 1. Probe scanout (pixels_ptr = 0) and negotiate preferred display size.
    try parent.space.writeGuestStruct(interface.GpuScanoutArgs, 0x8000_0000, .{
        .target_cid = child.local_cid,
        .width = 1008,
        .height = 630,
        .flags = interface.GpuScanoutFlags.SET_DISPLAY_SIZE,
    });
    handleGpuReadScanout(&p_vc, &ctx, parent, 0x8000_0000);
    try testing.expectEqual(@as(usize, 0), ctx[a0_reg]);
    try testing.expectEqual(@as(usize, 1), ctx[a1_reg]);
    try testing.expectEqual(@as(u32, 1008), child.gpu.display_width);
    try testing.expectEqual(@as(u32, 630), child.gpu.display_height);
    const probed = try parent.space.readGuestStruct(
        interface.GpuScanoutArgs,
        0x8000_0000,
    );
    try testing.expectEqual(@as(u32, 2), probed.width);
    try testing.expectEqual(@as(u32, 2), probed.height);

    // 2. Stream across a page boundary (first_page_offset = 4088 -> 2 px/page).
    const gpas = [_]u64{ 0x8000_1000, 0x8000_2000 };
    try parent.space.copyToGuest(0x8000_0200, std.mem.sliceAsBytes(&gpas));
    try parent.space.writeGuestStruct(interface.GpuScanoutArgs, 0x8000_0000, .{
        .target_cid = child.local_cid,
        .pixels_ptr = 0x8000_0200,
        .page_count = 2,
        .first_page_offset = 4088,
        .max_pixels = 4,
    });
    handleGpuReadScanout(&p_vc, &ctx, parent, 0x8000_0000);
    try testing.expectEqual(@as(usize, 0), ctx[a0_reg]);
    try testing.expectEqual(@as(usize, 1), ctx[a1_reg]);
    var p0: [2]u32 = undefined;
    var p1: [2]u32 = undefined;
    try parent.space.copyFromGuest(std.mem.sliceAsBytes(&p0), 0x8000_1ff8);
    try parent.space.copyFromGuest(std.mem.sliceAsBytes(&p1), 0x8000_2000);
    try testing.expectEqual(@as(u32, 0x00332211), p0[0]);
    try testing.expectEqual(@as(u32, 0x00665544), p0[1]);
    try testing.expectEqual(@as(u32, 0x00998877), p1[0]);
    try testing.expectEqual(@as(u32, 0x00ccbbaa), p1[1]);

    // 3. Inject input event batch and verify PLIC pending bit.
    var iargs = interface.InputEventArgs{
        .target_cid = child.local_cid,
        .count = 2,
    };
    iargs.events[0] = .{ .type = 1, .code = 30, .value = 1 };
    iargs.events[1] = .{ .type = 0, .code = 0, .value = 0 };
    try parent.space.writeGuestStruct(
        interface.InputEventArgs,
        0x8000_0400,
        iargs,
    );
    handleInputSendEvent(&p_vc, &ctx, parent, 0x8000_0400);
    try testing.expectEqual(@as(usize, 0), ctx[a0_reg]);
    try testing.expectEqual(@as(usize, 2), ctx[a1_reg]);
    try testing.expectEqual(@as(usize, 2), child.input.event_count);

    // 4. Confidential child denies both scanout readout and input injection.
    child.is_confidential = true;
    handleGpuReadScanout(&p_vc, &ctx, parent, 0x8000_0000);
    const denied: usize = @bitCast(sbi_core.SBI_ERR_DENIED);
    try testing.expectEqual(denied, ctx[a0_reg]);
    handleInputSendEvent(&p_vc, &ctx, parent, 0x8000_0400);
    try testing.expectEqual(denied, ctx[a0_reg]);
}
