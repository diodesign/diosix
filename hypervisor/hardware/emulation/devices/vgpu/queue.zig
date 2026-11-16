// VirtIO-GPU Split-Virtqueue Descriptor Chain Dispatcher
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const bus = @import("../bus.zig");
const vsock_mod = @import("../vsock.zig");
const proto = @import("protocol.zig");
const commands = @import("commands.zig");
const vgpu_mod = @import("../vgpu.zig");

const MemoryAccessor = vsock_mod.MemoryAccessor;
const VirtioGpu = vgpu_mod.VirtioGpu;
const VirtQueue = vgpu_mod.VirtQueue;
const VirtqDesc = bus.VirtqDesc;

const MAX_CHAIN_DESCS: usize = 64;
const STACK_SG_ENTRIES: usize = 32;

const ChainReader = struct {
    mem: MemoryAccessor,
    q: *const VirtQueue,
    cur_desc: VirtqDesc,
    offset_in_desc: u32 = 0,
    has_desc: bool = false,
    first_write_desc: ?VirtqDesc = null,
    steps: usize = 0,

    fn init(
        mem: MemoryAccessor,
        q: *const VirtQueue,
        head_idx: u16,
    ) ChainReader {
        var r = ChainReader{
            .mem = mem,
            .q = q,
            .cur_desc = undefined,
        };
        var d: VirtqDesc = undefined;
        if (head_idx < q.num and mem.read(
            q.desc_gpa +% (@as(u64, head_idx) *% @sizeOf(VirtqDesc)),
            std.mem.asBytes(&d),
        )) {
            if ((d.flags & bus.VIRTQ_DESC_F_WRITE) != 0) {
                r.first_write_desc = d;
            } else {
                r.cur_desc = d;
                r.has_desc = true;
            }
        }
        return r;
    }

    fn advanceToNextReadable(self: *ChainReader) bool {
        while (self.has_desc and
            (self.cur_desc.flags & bus.VIRTQ_DESC_F_NEXT) != 0 and
            self.steps < MAX_CHAIN_DESCS)
        {
            self.steps += 1;
            const next_idx = self.cur_desc.next;
            if (next_idx >= self.q.num) break;
            var next_d: VirtqDesc = undefined;
            if (!self.mem.read(
                self.q.desc_gpa +% (@as(u64, next_idx) *% @sizeOf(VirtqDesc)),
                std.mem.asBytes(&next_d),
            )) break;
            if ((next_d.flags & bus.VIRTQ_DESC_F_WRITE) != 0) {
                if (self.first_write_desc == null) {
                    self.first_write_desc = next_d;
                }
                self.has_desc = false;
                return false;
            }
            self.cur_desc = next_d;
            self.offset_in_desc = 0;
            return true;
        }
        self.has_desc = false;
        return false;
    }

    fn readBytes(self: *ChainReader, out: []u8) bool {
        var pos: usize = 0;
        while (pos < out.len) {
            if (!self.has_desc) return false;
            const rem_in_desc: usize =
                self.cur_desc.len -| self.offset_in_desc;
            if (rem_in_desc == 0) {
                if (!self.advanceToNextReadable()) return false;
                continue;
            }
            const chunk: usize = @min(out.len - pos, rem_in_desc);
            if (!self.mem.read(
                self.cur_desc.addr +% self.offset_in_desc,
                out[pos .. pos + chunk],
            )) return false;
            self.offset_in_desc += @intCast(chunk);
            pos += chunk;
        }
        return true;
    }

    fn findWriteDesc(self: *ChainReader) ?VirtqDesc {
        if (self.first_write_desc) |wd| return wd;
        while (self.advanceToNextReadable()) {}
        return self.first_write_desc;
    }
};

fn readReqPayload(
    comptime T: type,
    hdr: proto.VirtioGpuCtrlHdr,
    reader: *ChainReader,
) ?T {
    var req: T = undefined;
    const raw = std.mem.asBytes(&req);
    const hdr_len = @sizeOf(proto.VirtioGpuCtrlHdr);
    @memcpy(raw[0..hdr_len], std.mem.asBytes(&hdr));
    if (raw.len > hdr_len) {
        if (!reader.readBytes(raw[hdr_len..])) return null;
    }
    return req;
}

fn dispatchAttachBacking(
    gpu: *VirtioGpu,
    hdr: proto.VirtioGpuCtrlHdr,
    reader: *ChainReader,
) u32 {
    const req = readReqPayload(
        proto.VirtioGpuResourceAttachBacking,
        hdr,
        reader,
    ) orelse return proto.VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER;
    if (req.nr_entries > proto.MAX_BACKING_ENTRIES) {
        return proto.VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER;
    }
    if (req.nr_entries <= STACK_SG_ENTRIES) {
        const MemEntry = proto.VirtioGpuMemEntry;
        var stack_entries: [STACK_SG_ENTRIES]MemEntry = undefined;
        const slice = stack_entries[0..req.nr_entries];
        if (!reader.readBytes(std.mem.sliceAsBytes(slice))) {
            return proto.VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER;
        }
        return commands.handleAttachBackingSliceLocked(gpu, &req, slice);
    }
    const alloc = gpu.allocator orelse
        return proto.VIRTIO_GPU_RESP_ERR_OUT_OF_MEMORY;
    const heap_entries = alloc.alloc(
        proto.VirtioGpuMemEntry,
        req.nr_entries,
    ) catch return proto.VIRTIO_GPU_RESP_ERR_OUT_OF_MEMORY;
    defer alloc.free(heap_entries);
    if (!reader.readBytes(std.mem.sliceAsBytes(heap_entries))) {
        return proto.VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER;
    }
    return commands.handleAttachBackingSliceLocked(gpu, &req, heap_entries);
}

fn processSingleControlChain(
    gpu: *VirtioGpu,
    mem: MemoryAccessor,
    q: *VirtQueue,
    head_idx: u16,
) void {
    var reader = ChainReader.init(mem, q, head_idx);
    var hdr: proto.VirtioGpuCtrlHdr = .{};
    if (!reader.readBytes(std.mem.asBytes(&hdr))) {
        bus.pushVirtqUsed(mem, q, head_idx, 0);
        return;
    }

    if (hdr.type == proto.VIRTIO_GPU_CMD_GET_DISPLAY_INFO) {
        var disp: proto.VirtioGpuRespDisplayInfo = .{};
        commands.handleGetDisplayInfoLocked(gpu, &disp);
        disp.hdr = proto.initRespHdr(
            &hdr,
            proto.VIRTIO_GPU_RESP_OK_DISPLAY_INFO,
        );
        var written: u32 = 0;
        if (reader.findWriteDesc()) |wd| {
            const bytes = std.mem.asBytes(&disp);
            const len: usize = @min(@as(usize, wd.len), bytes.len);
            if (mem.write(wd.addr, bytes[0..len])) written = @intCast(len);
        }
        bus.pushVirtqUsed(mem, q, head_idx, written);
        return;
    }

    const err_param = proto.VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER;
    const status: u32 = switch (hdr.type) {
        proto.VIRTIO_GPU_CMD_RESOURCE_CREATE_2D => if (readReqPayload(
            proto.VirtioGpuResourceCreate2D,
            hdr,
            &reader,
        )) |r| commands.handleResourceCreate2DLocked(gpu, &r) else err_param,
        proto.VIRTIO_GPU_CMD_RESOURCE_UNREF => if (readReqPayload(
            proto.VirtioGpuResourceUnref,
            hdr,
            &reader,
        )) |r| commands.handleResourceUnrefLocked(gpu, &r) else err_param,
        proto.VIRTIO_GPU_CMD_SET_SCANOUT => if (readReqPayload(
            proto.VirtioGpuSetScanout,
            hdr,
            &reader,
        )) |r| commands.handleSetScanoutLocked(gpu, &r) else err_param,
        proto.VIRTIO_GPU_CMD_RESOURCE_FLUSH => if (readReqPayload(
            proto.VirtioGpuResourceFlush,
            hdr,
            &reader,
        )) |r| commands.handleResourceFlushLocked(gpu, &r) else err_param,
        proto.VIRTIO_GPU_CMD_TRANSFER_TO_HOST_2D => if (readReqPayload(
            proto.VirtioGpuTransferToHost2D,
            hdr,
            &reader,
        )) |r| commands.handleTransferToHost2DLocked(gpu, &r) else err_param,
        proto.VIRTIO_GPU_CMD_RESOURCE_ATTACH_BACKING => dispatchAttachBacking(
            gpu,
            hdr,
            &reader,
        ),
        proto.VIRTIO_GPU_CMD_RESOURCE_DETACH_BACKING => if (readReqPayload(
            proto.VirtioGpuResourceDetachBacking,
            hdr,
            &reader,
        )) |r| commands.handleDetachBackingLocked(gpu, &r) else err_param,
        else => proto.VIRTIO_GPU_RESP_ERR_UNSPEC,
    };

    const resp = proto.initRespHdr(&hdr, status);
    var written: u32 = 0;
    if (reader.findWriteDesc()) |wd| {
        const bytes = std.mem.asBytes(&resp);
        const len: usize = @min(@as(usize, wd.len), bytes.len);
        if (mem.write(wd.addr, bytes[0..len])) written = @intCast(len);
    }
    bus.pushVirtqUsed(mem, q, head_idx, written);
}

pub fn processQueueLocked(gpu: *VirtioGpu, queue_idx: usize) void {
    const mem = gpu.mem orelse {
        _ = gpu.interrupt_status.fetchOr(bus.VIRTIO_MMIO_INT_VRING, .acq_rel);
        return;
    };
    const q = &gpu.queues[queue_idx];
    if (!q.ready or q.num == 0 or q.driver_gpa == 0 or q.device_gpa == 0) {
        return;
    }
    var avail_idx: u16 = 0;
    if (!mem.read(
        q.driver_gpa +% bus.VIRTQ_RING_IDX_OFFSET,
        std.mem.asBytes(&avail_idx),
    )) return;

    var processed: u16 = 0;
    while (q.last_avail_idx != avail_idx and
        processed < q.num) : (processed += 1)
    {
        const slot = q.last_avail_idx % q.num;
        var head_idx: u16 = 0;
        const entry_off = bus.VIRTQ_RING_ELEMS_OFFSET +%
            (@as(u64, slot) *% @sizeOf(u16));
        if (!mem.read(
            q.driver_gpa +% entry_off,
            std.mem.asBytes(&head_idx),
        )) break;
        if (head_idx >= q.num) break;

        if (queue_idx == proto.QUEUE_INDEX_CONTROL) {
            processSingleControlChain(gpu, mem, q, head_idx);
        } else {
            var reader = ChainReader.init(mem, q, head_idx);
            var hdr: proto.VirtioGpuCtrlHdr = .{};
            if (reader.readBytes(std.mem.asBytes(&hdr))) {
                if (hdr.type == proto.VIRTIO_GPU_CMD_UPDATE_CURSOR or
                    hdr.type == proto.VIRTIO_GPU_CMD_MOVE_CURSOR)
                {
                    if (readReqPayload(
                        proto.VirtioGpuUpdateCursor,
                        hdr,
                        &reader,
                    )) |creq| {
                        commands.handleCursorLocked(
                            gpu,
                            &creq,
                            hdr.type == proto.VIRTIO_GPU_CMD_MOVE_CURSOR,
                        );
                    }
                }
            }
            var written: u32 = 0;
            if (reader.findWriteDesc()) |wd| {
                const resp = proto.initRespHdr(
                    &hdr,
                    proto.VIRTIO_GPU_RESP_OK_NODATA,
                );
                const bytes = std.mem.asBytes(&resp);
                const len: usize = @min(@as(usize, wd.len), bytes.len);
                if (mem.write(wd.addr, bytes[0..len])) written = @intCast(len);
            }
            bus.pushVirtqUsed(mem, q, head_idx, written);
        }
    }
    if (processed > 0) {
        _ = gpu.interrupt_status.fetchOr(bus.VIRTIO_MMIO_INT_VRING, .acq_rel);
    }
}

test "VirtIO GPU control virtqueue GET_DISPLAY_INFO chain execution" {
    const testing = std.testing;
    testing.refAllDecls(@This());

    const GuestRam = struct {
        buf: [4096]u8 = @splat(0),
        fn read(ctx: *anyopaque, gpa: u64, out: []u8) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const off: usize = @intCast(gpa);
            if (off + out.len > self.buf.len) return false;
            @memcpy(out, self.buf[off .. off + out.len]);
            return true;
        }
        fn write(ctx: *anyopaque, gpa: u64, data: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const off: usize = @intCast(gpa);
            if (off + data.len > self.buf.len) return false;
            @memcpy(self.buf[off .. off + data.len], data);
            return true;
        }
    };
    var ram = GuestRam{};
    var gpu = VirtioGpu.initWithMem(
        2,
        .{ .ctx = &ram, .readFn = GuestRam.read, .writeFn = GuestRam.write },
        testing.allocator,
    );
    defer gpu.deinit();

    // Chain: d0 (req @ 0x400) -> d1 (resp @ 0x500), avail 0x200, used 0x300.
    gpu.queues[0] = .{
        .num = 8,
        .ready = true,
        .desc_gpa = 0x000,
        .driver_gpa = 0x200,
        .device_gpa = 0x300,
    };
    const d0 = VirtqDesc{
        .addr = 0x400,
        .len = @sizeOf(proto.VirtioGpuCtrlHdr),
        .flags = bus.VIRTQ_DESC_F_NEXT,
        .next = 1,
    };
    const d1 = VirtqDesc{
        .addr = 0x500,
        .len = @sizeOf(proto.VirtioGpuRespDisplayInfo),
        .flags = bus.VIRTQ_DESC_F_WRITE,
        .next = 0,
    };
    @memcpy(ram.buf[0x000..0x010], std.mem.asBytes(&d0));
    @memcpy(ram.buf[0x010..0x020], std.mem.asBytes(&d1));
    const req = proto.VirtioGpuCtrlHdr{
        .type = proto.VIRTIO_GPU_CMD_GET_DISPLAY_INFO,
    };
    @memcpy(
        ram.buf[0x400..][0..@sizeOf(proto.VirtioGpuCtrlHdr)],
        std.mem.asBytes(&req),
    );
    std.mem.writeInt(u16, ram.buf[0x202..0x204], 1, .little); // avail.idx = 1.
    std.mem.writeInt(u16, ram.buf[0x204..0x206], 0, .little); // ring[0] = 0.

    processQueueLocked(&gpu, proto.QUEUE_INDEX_CONTROL);
    try testing.expectEqual(@as(u16, 1), gpu.queues[0].last_used_idx);
    var resp: proto.VirtioGpuRespDisplayInfo = undefined;
    @memcpy(
        std.mem.asBytes(&resp),
        ram.buf[0x500..][0..@sizeOf(proto.VirtioGpuRespDisplayInfo)],
    );
    try testing.expectEqual(
        proto.VIRTIO_GPU_RESP_OK_DISPLAY_INFO,
        resp.hdr.type,
    );
    try testing.expectEqual(
        proto.DEFAULT_DISPLAY_WIDTH,
        resp.pmodes[0].r.width,
    );
}
