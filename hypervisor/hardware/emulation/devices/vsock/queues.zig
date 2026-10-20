// VirtIO-vsock TX and RX Virtqueue Processing
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const bus = @import("../bus.zig");
const vsock_mod = @import("../vsock.zig");
const VirtioVsock = vsock_mod.VirtioVsock;
const VirtioVsockHdr = vsock_mod.VirtioVsockHdr;
const MemoryAccessor = vsock_mod.MemoryAccessor;
const VirtQueue = vsock_mod.VirtQueue;
const VirtqDesc = bus.VirtqDesc;
const VirtqUsedElem = bus.VirtqUsedElem;

fn pushUsedElem(
    mem: MemoryAccessor,
    q: *VirtQueue,
    desc_head_idx: u16,
    len: u32,
) void {
    const used_slot = q.last_used_idx % q.num;
    const used_elem = VirtqUsedElem{
        .id = desc_head_idx,
        .len = len,
    };
    const used_off = bus.VIRTQ_RING_ELEMS_OFFSET +%
        (@as(u64, used_slot) *% @sizeOf(VirtqUsedElem));
    const used_addr = q.device_gpa +% used_off;
    _ = mem.write(used_addr, std.mem.asBytes(&used_elem));

    q.last_used_idx +%= 1;
    _ = mem.write(
        q.device_gpa +% bus.VIRTQ_RING_IDX_OFFSET,
        std.mem.asBytes(&q.last_used_idx),
    );
    q.last_avail_idx +%= 1;
}

pub fn processTx(self: *VirtioVsock) void {
    while (self.tx_lock.swap(true, .acquire)) {
        std.atomic.spinLoopHint();
    }
    defer self.tx_lock.store(false, .release);

    const mem = self.mem orelse return;
    const tx_q = &self.queues[vsock_mod.QUEUE_INDEX_TX];
    if (!tx_q.ready or tx_q.num == 0 or
        tx_q.driver_gpa == 0 or tx_q.device_gpa == 0)
    {
        return;
    }

    var avail_idx: u16 = 0;
    if (!mem.read(
        tx_q.driver_gpa +% bus.VIRTQ_RING_IDX_OFFSET,
        std.mem.asBytes(&avail_idx),
    )) {
        return;
    }

    var processed_count: u16 = 0;
    while (tx_q.last_avail_idx != avail_idx and
        processed_count < tx_q.num) : (processed_count += 1)
    {
        const ring_slot = tx_q.last_avail_idx % tx_q.num;
        var desc_head_idx: u16 = 0;
        const ring_entry_offset = bus.VIRTQ_RING_ELEMS_OFFSET +%
            (@as(u64, ring_slot) *% @sizeOf(u16));
        if (!mem.read(
            tx_q.driver_gpa +% ring_entry_offset,
            std.mem.asBytes(&desc_head_idx),
        )) break;

        if (desc_head_idx >= tx_q.num) break;

        var desc: VirtqDesc = undefined;
        const desc_offset = @as(u64, desc_head_idx) *% @sizeOf(VirtqDesc);
        const desc_addr = tx_q.desc_gpa +% desc_offset;
        if (!mem.read(desc_addr, std.mem.asBytes(&desc))) break;

        if (desc.len >= @sizeOf(VirtioVsockHdr)) {
            var hdr: VirtioVsockHdr = undefined;
            if (mem.read(desc.addr, std.mem.asBytes(&hdr))) {
                var payload_buf: [vsock_mod.MAX_PACKET_PAYLOAD]u8 = undefined;
                var payload_slice: []const u8 = &.{};
                const payload_len: usize = @min(hdr.len, payload_buf.len);

                if (payload_len > 0) {
                    if (desc.len > @sizeOf(VirtioVsockHdr)) {
                        const avail_in_desc: usize = @min(
                            payload_len,
                            desc.len - @sizeOf(VirtioVsockHdr),
                        );
                        const pay_gpa = desc.addr +% @sizeOf(VirtioVsockHdr);
                        if (mem.read(
                            pay_gpa,
                            payload_buf[0..avail_in_desc],
                        )) {
                            payload_slice = payload_buf[0..avail_in_desc];
                        }
                    } else if ((desc.flags & bus.VIRTQ_DESC_F_NEXT) != 0 and
                        desc.next < tx_q.num)
                    {
                        var next_desc: VirtqDesc = undefined;
                        const next_off =
                            @as(u64, desc.next) *% @sizeOf(VirtqDesc);
                        const next_addr = tx_q.desc_gpa +% next_off;
                        if (mem.read(
                            next_addr,
                            std.mem.asBytes(&next_desc),
                        )) {
                            const copy_len: usize =
                                @min(payload_len, next_desc.len);
                            if (mem.read(
                                next_desc.addr,
                                payload_buf[0..copy_len],
                            )) {
                                payload_slice = payload_buf[0..copy_len];
                            }
                        }
                    }
                }

                if (self.router) |r| {
                    _ = r.routePacket(self, &hdr, payload_slice);
                }
            }
        }

        pushUsedElem(mem, tx_q, desc_head_idx, 0);
    }

    _ = @atomicRmw(u32, &self.interrupt_status, .Or, 1, .seq_cst);
}

pub fn deliverRxPacket(
    self: *VirtioVsock,
    hdr: *const VirtioVsockHdr,
    payload: []const u8,
) bool {
    while (self.rx_lock.swap(true, .acquire)) {
        std.atomic.spinLoopHint();
    }
    defer self.rx_lock.store(false, .release);

    const mem = self.mem orelse return false;
    const rx_q = &self.queues[vsock_mod.QUEUE_INDEX_RX];
    if (!rx_q.ready or rx_q.num == 0 or
        rx_q.driver_gpa == 0 or rx_q.device_gpa == 0)
    {
        return false;
    }

    var avail_idx: u16 = 0;
    if (!mem.read(
        rx_q.driver_gpa +% bus.VIRTQ_RING_IDX_OFFSET,
        std.mem.asBytes(&avail_idx),
    )) {
        return false;
    }
    if (rx_q.last_avail_idx == avail_idx) return false;

    const ring_slot = rx_q.last_avail_idx % rx_q.num;
    var desc_head_idx: u16 = 0;
    const ring_entry_offset = bus.VIRTQ_RING_ELEMS_OFFSET +%
        (@as(u64, ring_slot) *% @sizeOf(u16));
    if (!mem.read(
        rx_q.driver_gpa +% ring_entry_offset,
        std.mem.asBytes(&desc_head_idx),
    )) return false;

    if (desc_head_idx >= rx_q.num) return false;

    var desc: VirtqDesc = undefined;
    const desc_offset = @as(u64, desc_head_idx) *% @sizeOf(VirtqDesc);
    const desc_addr = rx_q.desc_gpa +% desc_offset;
    if (!mem.read(desc_addr, std.mem.asBytes(&desc))) return false;

    if (desc.len < @sizeOf(VirtioVsockHdr)) return false;
    if ((desc.flags & bus.VIRTQ_DESC_F_WRITE) == 0) return false;

    var rx_hdr = hdr.*;
    var payload_written: u32 = 0;

    if (payload.len > 0) {
        const needed_len = std.math.add(
            usize,
            @sizeOf(VirtioVsockHdr),
            payload.len,
        ) catch std.math.maxInt(usize);
        if (desc.len >= needed_len) {
            if (mem.write(desc.addr +% @sizeOf(VirtioVsockHdr), payload)) {
                payload_written = @truncate(payload.len);
            }
        } else if ((desc.flags & bus.VIRTQ_DESC_F_NEXT) != 0 and
            desc.next < rx_q.num)
        {
            var next_desc: VirtqDesc = undefined;
            const next_off = @as(u64, desc.next) *% @sizeOf(VirtqDesc);
            const next_addr = rx_q.desc_gpa +% next_off;
            if (mem.read(next_addr, std.mem.asBytes(&next_desc))) {
                if ((next_desc.flags & bus.VIRTQ_DESC_F_WRITE) != 0) {
                    const copy_len: usize = @min(payload.len, next_desc.len);
                    if (mem.write(next_desc.addr, payload[0..copy_len])) {
                        payload_written = @truncate(copy_len);
                    }
                }
            }
        }
    }

    rx_hdr.len = payload_written;
    if (!mem.write(desc.addr, std.mem.asBytes(&rx_hdr))) return false;

    const total_written: u32 = @sizeOf(VirtioVsockHdr) + payload_written;
    pushUsedElem(mem, rx_q, desc_head_idx, total_written);

    _ = @atomicRmw(u32, &self.interrupt_status, .Or, 1, .seq_cst);
    return true;
}

test "VirtIO-vsock inter-VM packet routing and queue bounds" {
    const testing = std.testing;
    testing.refAllDecls(@This());

    const MOCK_RAM_BYTES: usize = 65536;
    const MockRam = struct {
        buffer: [MOCK_RAM_BYTES]u8 = @splat(0),

        fn read(ctx: *anyopaque, gpa: u64, buf: []u8) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const end = std.math.add(u64, gpa, buf.len) catch return false;
            if (end > self.buffer.len) return false;
            @memcpy(buf, self.buffer[@intCast(gpa)..@intCast(end)]);
            return true;
        }

        fn write(ctx: *anyopaque, gpa: u64, buf: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const end = std.math.add(u64, gpa, buf.len) catch return false;
            if (end > self.buffer.len) return false;
            @memcpy(self.buffer[@intCast(gpa)..@intCast(end)], buf);
            return true;
        }

        fn accessor(self: *@This()) MemoryAccessor {
            return .{
                .ctx = self,
                .readFn = read,
                .writeFn = write,
            };
        }
    };

    var router = vsock_mod.VsockRouter{};
    var ram1 = MockRam{};
    var ram2 = MockRam{};

    const mem1 = ram1.accessor();
    const mem2 = ram2.accessor();

    var root_vsock = VirtioVsock{
        .guest_cid = 1,
        .mem = mem1,
        .router = &router,
    };
    var guest_vsock = VirtioVsock{
        .guest_cid = 2,
        .mem = mem2,
        .router = &router,
    };

    router.register(&root_vsock);
    router.register(&guest_vsock);

    guest_vsock.queues[vsock_mod.QUEUE_INDEX_RX] = .{
        .ready = true,
        .desc_gpa = 0x1000,
        .driver_gpa = 0x2000,
        .device_gpa = 0x3000,
        .last_avail_idx = 0,
        .last_used_idx = 0,
    };

    const rx_desc = VirtqDesc{
        .addr = 0x4000,
        .len = 2048,
        .flags = bus.VIRTQ_DESC_F_WRITE,
        .next = 0,
    };
    _ = mem2.write(0x1000, std.mem.asBytes(&rx_desc));

    const rx_desc_head: u16 = 0;
    _ = mem2.write(0x2004, std.mem.asBytes(&rx_desc_head));
    const avail_idx: u16 = 1;
    _ = mem2.write(0x2002, std.mem.asBytes(&avail_idx));

    const tx_hdr = VirtioVsockHdr{
        .src_cid = 1,
        .dst_cid = 2,
        .src_port = 1024,
        .dst_port = 22,
        .len = 5,
        .type = vsock_mod.VIRTIO_VSOCK_TYPE_STREAM,
        .op = vsock_mod.VIRTIO_VSOCK_OP_RW,
        .flags = 0,
        .buf_alloc = 65536,
        .fwd_cnt = 0,
    };

    const routed = router.routePacket(&root_vsock, &tx_hdr, "HELLO");
    try testing.expect(routed);

    var received_hdr: VirtioVsockHdr = undefined;
    _ = mem2.read(0x4000, std.mem.asBytes(&received_hdr));
    try testing.expectEqual(@as(u64, 1), received_hdr.src_cid);
    try testing.expectEqual(@as(u64, 2), received_hdr.dst_cid);
    try testing.expectEqual(@as(u32, 1024), received_hdr.src_port);
    try testing.expectEqual(@as(u32, 22), received_hdr.dst_port);
    try testing.expectEqual(vsock_mod.VIRTIO_VSOCK_OP_RW, received_hdr.op);

    var received_payload: [5]u8 = undefined;
    _ = mem2.read(0x4000 + @sizeOf(VirtioVsockHdr), &received_payload);
    try testing.expectEqualStrings("HELLO", &received_payload);
    try testing.expect(guest_vsock.interrupt_status & 1 != 0);

    // Safety against zero queue size and OOB descriptor heads.
    var ram3 = MockRam{};
    const mem3 = ram3.accessor();
    var vsock = VirtioVsock.init(3, mem3);

    vsock.writeReg(0x030, vsock_mod.QUEUE_INDEX_TX);
    vsock.writeReg(0x038, 0);
    try testing.expect(vsock.queues[vsock_mod.QUEUE_INDEX_TX].num > 0);

    vsock.queues[vsock_mod.QUEUE_INDEX_TX].num = 0;
    vsock.queues[vsock_mod.QUEUE_INDEX_TX].ready = true;
    vsock.processTx();

    vsock.queues[vsock_mod.QUEUE_INDEX_TX] = .{
        .num = 16,
        .ready = true,
        .desc_gpa = 0x1000,
        .driver_gpa = 0x2000,
        .device_gpa = 0x3000,
    };
    const bad_avail_idx: u16 = 1;
    _ = mem3.write(0x2002, std.mem.asBytes(&bad_avail_idx));
    const bad_desc_head: u16 = 999;
    _ = mem3.write(0x2004, std.mem.asBytes(&bad_desc_head));

    vsock.processTx();
    try testing.expectEqual(
        @as(u16, 0),
        vsock.queues[vsock_mod.QUEUE_INDEX_TX].last_used_idx,
    );
}
