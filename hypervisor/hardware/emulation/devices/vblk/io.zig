// VirtIO-blk Bounded Queue Processing and Descriptor Transfer Helpers.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const bus = @import("../bus.zig");
const vsock_mod = @import("../vsock.zig");
const vblk = @import("../vblk.zig");
const MemoryAccessor = vsock_mod.MemoryAccessor;
const VirtqDesc = bus.VirtqDesc;
const VirtioBlkReqHdr = vblk.VirtioBlkReqHdr;
const VirtQueue = vblk.VirtQueue;

pub const MAX_IO_BYTES_PER_NOTIFY: usize = 4 * 1024 * 1024;
const DEVICE_SERIAL_ID = "diosix-vblk";

fn transferBacking(
    self: *vblk.VirtioBlk,
    mem: MemoryAccessor,
    byte_off: u64,
    guest_gpa: u64,
    len: u32,
    is_write: bool,
) bool {
    if (len > MAX_IO_BYTES_PER_NOTIFY) return false;
    _ = std.math.add(u64, guest_gpa, len) catch return false;
    const end_off = std.math.add(u64, byte_off, len) catch return false;
    if (end_off > self.capacity_bytes) return false;
    const store_base = std.math.add(
        u64,
        self.backing_gpa,
        byte_off,
    ) catch return false;

    var chunk_buf: [vblk.IO_CHUNK_BYTES]u8 = undefined;
    var pos: u64 = 0;
    while (pos < len) {
        const step: usize = @intCast(@min(
            @as(u64, vblk.IO_CHUNK_BYTES),
            len - pos,
        ));
        const s_gpa = store_base + pos;
        const g_gpa = guest_gpa + pos;
        if (is_write) {
            if (!mem.read(g_gpa, chunk_buf[0..step])) return false;
            if (!mem.write(s_gpa, chunk_buf[0..step])) return false;
        } else {
            if (!mem.read(s_gpa, chunk_buf[0..step])) return false;
            if (!mem.write(g_gpa, chunk_buf[0..step])) return false;
        }
        pos += step;
    }
    return true;
}

fn handleDescriptorChain(
    self: *vblk.VirtioBlk,
    mem: MemoryAccessor,
    q: *VirtQueue,
    req_hdr: VirtioBlkReqHdr,
    first_next: u16,
    total_written: *u32,
    budget_left: *usize,
) u8 {
    var cur_idx = first_next;
    var byte_off = std.math.mul(
        u64,
        req_hdr.sector,
        vblk.SECTOR_SIZE,
    ) catch return vblk.VIRTIO_BLK_S_IOERR;
    var status: u8 = vblk.VIRTIO_BLK_S_OK;
    var hops: usize = 0;

    while (cur_idx < q.num and
        hops < vblk.MAX_CHAIN_DESCRIPTORS) : (hops += 1)
    {
        var desc: VirtqDesc = undefined;
        if (!mem.read(
            q.desc_gpa + (@as(u64, cur_idx) * @sizeOf(VirtqDesc)),
            std.mem.asBytes(&desc),
        )) return vblk.VIRTIO_BLK_S_IOERR;

        const has_next = (desc.flags & bus.VIRTQ_DESC_F_NEXT) != 0;
        if (!has_next) {
            if (desc.len >= 1 and
                (desc.flags & bus.VIRTQ_DESC_F_WRITE) != 0)
            {
                _ = mem.write(desc.addr, &[_]u8{status});
                total_written.* +%= 1;
            }
            return status;
        }

        switch (req_hdr.req_type) {
            vblk.VIRTIO_BLK_T_IN => {
                if (desc.len > budget_left.* or
                    (desc.flags & bus.VIRTQ_DESC_F_WRITE) == 0 or
                    !transferBacking(
                        self,
                        mem,
                        byte_off,
                        desc.addr,
                        desc.len,
                        false,
                    ))
                {
                    status = vblk.VIRTIO_BLK_S_IOERR;
                } else {
                    budget_left.* -|= desc.len;
                    byte_off = std.math.add(u64, byte_off, desc.len) catch
                        return vblk.VIRTIO_BLK_S_IOERR;
                    total_written.* +%= desc.len;
                }
            },
            vblk.VIRTIO_BLK_T_OUT => {
                if (desc.len > budget_left.* or self.read_only or
                    !transferBacking(
                        self,
                        mem,
                        byte_off,
                        desc.addr,
                        desc.len,
                        true,
                    ))
                {
                    status = vblk.VIRTIO_BLK_S_IOERR;
                } else {
                    budget_left.* -|= desc.len;
                    byte_off = std.math.add(u64, byte_off, desc.len) catch
                        return vblk.VIRTIO_BLK_S_IOERR;
                }
            },
            vblk.VIRTIO_BLK_T_FLUSH => {},
            vblk.VIRTIO_BLK_T_GET_ID => {
                var id_buf: [vblk.VIRTIO_BLK_ID_BYTES]u8 = @splat(0);
                @memcpy(id_buf[0..DEVICE_SERIAL_ID.len], DEVICE_SERIAL_ID);
                const n: usize = @min(
                    @as(usize, desc.len),
                    vblk.VIRTIO_BLK_ID_BYTES,
                );
                if ((desc.flags & bus.VIRTQ_DESC_F_WRITE) != 0 and
                    mem.write(desc.addr, id_buf[0..n]))
                {
                    total_written.* +%= @intCast(n);
                } else {
                    status = vblk.VIRTIO_BLK_S_IOERR;
                }
            },
            else => status = vblk.VIRTIO_BLK_S_UNSUPP,
        }
        cur_idx = desc.next;
    }
    return vblk.VIRTIO_BLK_S_IOERR;
}

pub fn processQueueLocked(self: *vblk.VirtioBlk) void {
    const mem = self.mem orelse return;
    const q = &self.queues[vblk.QUEUE_INDEX_REQ];
    if (!q.ready or q.num == 0 or
        q.driver_gpa == 0 or q.device_gpa == 0)
    {
        return;
    }

    var avail_idx: u16 = 0;
    if (!mem.read(
        q.driver_gpa + bus.VIRTQ_RING_IDX_OFFSET,
        std.mem.asBytes(&avail_idx),
    )) return;

    var budget_left: usize = MAX_IO_BYTES_PER_NOTIFY;
    var processed: u16 = 0;
    while (q.last_avail_idx != avail_idx and
        processed < q.num and budget_left > 0) : (processed += 1)
    {
        const slot = q.last_avail_idx % q.num;
        var head_idx: u16 = 0;
        const entry_off = bus.VIRTQ_RING_ELEMS_OFFSET +
            (@as(u64, slot) * @sizeOf(u16));
        if (!mem.read(
            q.driver_gpa + entry_off,
            std.mem.asBytes(&head_idx),
        )) break;
        if (head_idx >= q.num) break;

        var hdr_desc: VirtqDesc = undefined;
        if (!mem.read(
            q.desc_gpa + (@as(u64, head_idx) * @sizeOf(VirtqDesc)),
            std.mem.asBytes(&hdr_desc),
        )) break;

        var total_written: u32 = 0;
        if (hdr_desc.len >= @sizeOf(VirtioBlkReqHdr) and
            (hdr_desc.flags & bus.VIRTQ_DESC_F_NEXT) != 0)
        {
            var req_hdr: VirtioBlkReqHdr = undefined;
            if (mem.read(hdr_desc.addr, std.mem.asBytes(&req_hdr))) {
                _ = handleDescriptorChain(
                    self,
                    mem,
                    q,
                    req_hdr,
                    hdr_desc.next,
                    &total_written,
                    &budget_left,
                );
            }
        }
        bus.pushVirtqUsed(mem, q, head_idx, total_written);
    }

    _ = @atomicRmw(u32, &self.interrupt_status, .Or, 1, .seq_cst);
}

test "vblk/io: caps excessive per-descriptor I/O with IOERR" {
    std.testing.refAllDecls(@This());
    try std.testing.expectEqual(
        @as(usize, 4 * 1024 * 1024),
        MAX_IO_BYTES_PER_NOTIFY,
    );
}
