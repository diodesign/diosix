// Memory Mapped I/O (MMIO) Bus Router for Diosix Virtual Devices
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const vuart_mod = @import("vuart.zig");
const vtimer_mod = @import("vtimer.zig");
const vpic_mod = @import("vpic.zig");
const vsock_mod = @import("vsock.zig");
const vblk_mod = @import("vblk.zig");
const vnet_mod = @import("vnet.zig");
const vcpu_mod = @import("../vcpu.zig");

pub const MMIO_UART_BASE: u32 = 0x10000000;
pub const MMIO_UART_SIZE: u32 = 0x100;
pub const MMIO_VIRTIO_BASE: u32 = 0x10001000;
pub const MMIO_VIRTIO_END: u32 = 0x10009000;
pub const MMIO_CLINT_BASE: u32 = 0x02000000;
pub const MMIO_CLINT_SIZE: u32 = 0x00010000;
pub const MMIO_PLIC_BASE: u32 = 0x0c000000;
pub const MMIO_PLIC_END: u32 = 0x10000000;
pub const MMIO_TEST_RTC_BASE: u32 = 0x00100000;
pub const MMIO_RTC_BASE: u32 = 0x00101000;
pub const MMIO_TEST_RTC_END: u32 = 0x00102000;

pub const VIRTIO_SLOT_STRIDE: u32 = 0x1000;
pub const VIRTIO_SLOT_OFFSET_MASK: u32 = VIRTIO_SLOT_STRIDE - 1;
pub const VIRTIO_SLOT_VSOCK: u32 = 0;
pub const VIRTIO_SLOT_BLK: u32 = 3;
pub const VIRTIO_SLOT_NET: u32 = 4;

pub const IRQ_VIRTIO_VSOCK: u32 = 1;
pub const IRQ_VIRTIO_BLK: u32 = 4;
pub const IRQ_VIRTIO_NET: u32 = 5;
pub const IRQ_UART0: u32 = 10;

pub const RTC_TIME_LOW: u32 = 0x00;
pub const RTC_TIME_HIGH: u32 = 0x04;
pub const RTC_TICKS_TO_NS: u64 = 100;

pub const LOW_WORD_MASK: u64 = 0x0000_0000_ffff_ffff;
pub const HIGH_WORD_MASK: u64 = 0xffff_ffff_0000_0000;
pub const HIGH_WORD_SHIFT: u6 = 32;

pub inline fn memoryBarrier() void {
    const arch = @import("builtin").cpu.arch;
    if (comptime arch == .riscv64 or arch == .riscv32) {
        asm volatile ("fence rw, rw" ::: .{ .memory = true });
    } else {
        var guard: u8 = 0;
        _ = @atomicRmw(u8, &guard, .Xchg, 1, .seq_cst);
    }
}

pub inline fn setLow32(cur: u64, val: u32) u64 {
    return (cur & HIGH_WORD_MASK) | val;
}

pub inline fn setHigh32(cur: u64, val: u32) u64 {
    return (cur & LOW_WORD_MASK) | (@as(u64, val) << HIGH_WORD_SHIFT);
}

pub const VIRTIO_MMIO_MAGIC: u32 = 0x74726976; // "virt" in little-endian.
pub const VIRTIO_MMIO_VERSION_2: u32 = 0x00000002; // Modern VirtIO.
pub const VIRTIO_MMIO_DEVICE_NONE: u32 = 0x00000000; // Empty slot.
pub const VIRTIO_MMIO_VENDOR_QEMU: u32 = 0x554d4551; // "QEMU".

pub const VIRTIO_F_VERSION_1_SEL: u32 = 1;
pub const VIRTIO_F_VERSION_1_BIT: u32 = 1;

// Canonical VirtIO MMIO Register Offsets (VirtIO 1.1 Spec Section 4.2.2).
pub const VIRTIO_MMIO_REG_MAGIC_VALUE: u32 = 0x000;
pub const VIRTIO_MMIO_REG_VERSION: u32 = 0x004;
pub const VIRTIO_MMIO_REG_DEVICE_ID: u32 = 0x008;
pub const VIRTIO_MMIO_REG_VENDOR_ID: u32 = 0x00c;
pub const VIRTIO_MMIO_REG_DEVICE_FEATURES: u32 = 0x010;
pub const VIRTIO_MMIO_REG_DEVICE_FEATURES_SEL: u32 = 0x014;
pub const VIRTIO_MMIO_REG_DRIVER_FEATURES: u32 = 0x020;
pub const VIRTIO_MMIO_REG_DRIVER_FEATURES_SEL: u32 = 0x024;
pub const VIRTIO_MMIO_REG_QUEUE_SEL: u32 = 0x030;
pub const VIRTIO_MMIO_REG_QUEUE_NUM_MAX: u32 = 0x034;
pub const VIRTIO_MMIO_REG_QUEUE_NUM: u32 = 0x038;
pub const VIRTIO_MMIO_REG_QUEUE_READY: u32 = 0x044;
pub const VIRTIO_MMIO_REG_QUEUE_NOTIFY: u32 = 0x050;
pub const VIRTIO_MMIO_REG_INTERRUPT_STATUS: u32 = 0x060;
pub const VIRTIO_MMIO_REG_INTERRUPT_ACK: u32 = 0x064;
pub const VIRTIO_MMIO_REG_STATUS: u32 = 0x070;
pub const VIRTIO_MMIO_REG_QUEUE_DESC_LOW: u32 = 0x080;
pub const VIRTIO_MMIO_REG_QUEUE_DESC_HIGH: u32 = 0x084;
pub const VIRTIO_MMIO_REG_QUEUE_DRIVER_LOW: u32 = 0x090;
pub const VIRTIO_MMIO_REG_QUEUE_DRIVER_HIGH: u32 = 0x094;
pub const VIRTIO_MMIO_REG_QUEUE_DEVICE_LOW: u32 = 0x0a0;
pub const VIRTIO_MMIO_REG_QUEUE_DEVICE_HIGH: u32 = 0x0a4;
pub const VIRTIO_MMIO_REG_SHM_SEL: u32 = 0x0ac;
pub const VIRTIO_MMIO_REG_SHM_LEN_LOW: u32 = 0x0b0;
pub const VIRTIO_MMIO_REG_SHM_LEN_HIGH: u32 = 0x0b4;
pub const VIRTIO_MMIO_REG_SHM_BASE_LOW: u32 = 0x0b8;
pub const VIRTIO_MMIO_REG_SHM_BASE_HIGH: u32 = 0x0bc;
pub const VIRTIO_MMIO_REG_CONFIG_GENERATION: u32 = 0x0fc;
pub const VIRTIO_MMIO_REG_CONFIG_BASE: u32 = 0x100;
pub const VIRTIO_MMIO_REG_SHM_NONE: u32 = 0xffff_ffff;
pub const VIRTIO_MMIO_INT_VRING: u32 = 1 << 0;
pub const VIRTIO_MMIO_INT_CONFIG: u32 = 1 << 1;
pub const VIRTIO_CONFIG_S_DRIVER_OK: u32 = 1 << 2;

// Shared VirtIO Descriptor & Split-Virtqueue Definitions (VirtIO 1.1 Sec 2.6).
pub const VIRTQ_DESC_F_NEXT: u16 = 1;
pub const VIRTQ_DESC_F_WRITE: u16 = 2;
pub const VIRTQ_RING_IDX_OFFSET: u64 = 2;
pub const VIRTQ_RING_ELEMS_OFFSET: u64 = 4;

pub const VirtqDesc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};

pub const VirtqUsedElem = extern struct {
    id: u32,
    len: u32,
};

comptime {
    std.debug.assert(@sizeOf(VirtqDesc) == 16);
    std.debug.assert(@sizeOf(VirtqUsedElem) == 8);
}

pub fn VirtQueueConfig(comptime default_num: u16) type {
    return struct {
        num: u16 = default_num,
        ready: bool = false,
        desc_gpa: u64 = 0,
        driver_gpa: u64 = 0,
        device_gpa: u64 = 0,
        last_avail_idx: u16 = 0,
        last_used_idx: u16 = 0,
    };
}

/// Push a completed descriptor chain head onto a split-virtqueue used ring.
pub fn pushVirtqUsed(
    mem: vsock_mod.MemoryAccessor,
    q: anytype,
    head_idx: u16,
    written_len: u32,
) void {
    const used_slot = q.last_used_idx % q.num;
    const elem = VirtqUsedElem{ .id = head_idx, .len = written_len };
    const elem_off = VIRTQ_RING_ELEMS_OFFSET +%
        (@as(u64, used_slot) *% @sizeOf(VirtqUsedElem));
    _ = mem.write(q.device_gpa +% elem_off, std.mem.asBytes(&elem));
    memoryBarrier();
    q.last_used_idx +%= 1;
    _ = mem.write(
        q.device_gpa +% VIRTQ_RING_IDX_OFFSET,
        std.mem.asBytes(&q.last_used_idx),
    );
    q.last_avail_idx +%= 1;
}

/// Shared handler for reading standard VirtIO MMIO transport header registers.
/// Returns the 32-bit register value if `offset` is a common transport
/// register, or `null` if it is device-specific config space.
pub fn readVirtioCommon(
    dev: anytype,
    comptime device_id: u32,
    comptime num_queues: usize,
    comptime queue_size_max: u16,
    irq_status: u32,
    offset: u32,
) ?u32 {
    const q_valid = dev.queue_sel < num_queues;
    const feat_v1: u32 = if (dev.device_features_sel == VIRTIO_F_VERSION_1_SEL)
        VIRTIO_F_VERSION_1_BIT
    else
        0;
    return switch (offset) {
        VIRTIO_MMIO_REG_MAGIC_VALUE => VIRTIO_MMIO_MAGIC,
        VIRTIO_MMIO_REG_VERSION => VIRTIO_MMIO_VERSION_2,
        VIRTIO_MMIO_REG_DEVICE_ID => device_id,
        VIRTIO_MMIO_REG_VENDOR_ID => VIRTIO_MMIO_VENDOR_QEMU,
        VIRTIO_MMIO_REG_DEVICE_FEATURES => feat_v1,
        VIRTIO_MMIO_REG_QUEUE_NUM_MAX => if (q_valid) queue_size_max else 0,
        VIRTIO_MMIO_REG_QUEUE_READY => if (q_valid and
            dev.queues[dev.queue_sel].ready)
            1
        else
            0,
        VIRTIO_MMIO_REG_INTERRUPT_STATUS => irq_status,
        VIRTIO_MMIO_REG_STATUS => dev.status,
        VIRTIO_MMIO_REG_SHM_LEN_LOW,
        VIRTIO_MMIO_REG_SHM_LEN_HIGH,
        VIRTIO_MMIO_REG_SHM_BASE_LOW,
        VIRTIO_MMIO_REG_SHM_BASE_HIGH,
        => VIRTIO_MMIO_REG_SHM_NONE,
        VIRTIO_MMIO_REG_CONFIG_GENERATION => 0,
        else => null,
    };
}

fn isValidVirtqRings(q: anytype) bool {
    if (q.num == 0) return false;
    const n: u64 = q.num;
    const desc_sz = n * @sizeOf(VirtqDesc);
    const avail_sz = VIRTQ_RING_ELEMS_OFFSET + (n * @sizeOf(u16));
    const used_sz = VIRTQ_RING_ELEMS_OFFSET + (n * @sizeOf(VirtqUsedElem));
    _ = std.math.add(u64, q.desc_gpa, desc_sz) catch return false;
    _ = std.math.add(u64, q.driver_gpa, avail_sz) catch return false;
    _ = std.math.add(u64, q.device_gpa, used_sz) catch return false;
    return true;
}

/// Shared handler for standard VirtIO MMIO feature and split-virtqueue
/// configuration registers. Returns true if the register offset was handled.
pub fn writeVirtioQueueAndFeatureReg(
    dev: anytype,
    comptime num_queues: usize,
    comptime queue_size_max: u16,
    offset: u32,
    val: u32,
) bool {
    switch (offset) {
        VIRTIO_MMIO_REG_DEVICE_FEATURES_SEL => dev.device_features_sel = val,
        VIRTIO_MMIO_REG_DRIVER_FEATURES => {
            if (dev.driver_features_sel == 0) {
                dev.driver_features = setLow32(dev.driver_features, val);
            } else if (dev.driver_features_sel == VIRTIO_F_VERSION_1_SEL) {
                dev.driver_features = setHigh32(dev.driver_features, val);
            }
        },
        VIRTIO_MMIO_REG_DRIVER_FEATURES_SEL => dev.driver_features_sel = val,
        VIRTIO_MMIO_REG_QUEUE_SEL => dev.queue_sel = val,
        VIRTIO_MMIO_REG_QUEUE_NUM => {
            if (dev.queue_sel < num_queues) {
                const q_num: u16 = @min(val, queue_size_max);
                if (q_num > 0) {
                    dev.queues[dev.queue_sel].num = q_num;
                }
            }
        },
        VIRTIO_MMIO_REG_QUEUE_READY => {
            if (dev.queue_sel < num_queues) {
                const q = &dev.queues[dev.queue_sel];
                q.ready = (val & 1) != 0 and isValidVirtqRings(q);
            }
        },
        VIRTIO_MMIO_REG_QUEUE_DESC_LOW => {
            if (dev.queue_sel < num_queues) {
                const q = &dev.queues[dev.queue_sel];
                q.desc_gpa = setLow32(q.desc_gpa, val);
            }
        },
        VIRTIO_MMIO_REG_QUEUE_DESC_HIGH => {
            if (dev.queue_sel < num_queues) {
                const q = &dev.queues[dev.queue_sel];
                q.desc_gpa = setHigh32(q.desc_gpa, val);
            }
        },
        VIRTIO_MMIO_REG_QUEUE_DRIVER_LOW => {
            if (dev.queue_sel < num_queues) {
                const q = &dev.queues[dev.queue_sel];
                q.driver_gpa = setLow32(q.driver_gpa, val);
            }
        },
        VIRTIO_MMIO_REG_QUEUE_DRIVER_HIGH => {
            if (dev.queue_sel < num_queues) {
                const q = &dev.queues[dev.queue_sel];
                q.driver_gpa = setHigh32(q.driver_gpa, val);
            }
        },
        VIRTIO_MMIO_REG_QUEUE_DEVICE_LOW => {
            if (dev.queue_sel < num_queues) {
                const q = &dev.queues[dev.queue_sel];
                q.device_gpa = setLow32(q.device_gpa, val);
            }
        },
        VIRTIO_MMIO_REG_QUEUE_DEVICE_HIGH => {
            if (dev.queue_sel < num_queues) {
                const q = &dev.queues[dev.queue_sel];
                q.device_gpa = setHigh32(q.device_gpa, val);
            }
        },
        VIRTIO_MMIO_REG_SHM_SEL => {},
        else => return false,
    }
    return true;
}

pub const Bus = struct {
    uart: *vuart_mod.VirtualUart,
    timer: *vtimer_mod.VirtualTimer,
    pic: *vpic_mod.VirtualPlic,
    vsock: ?*vsock_mod.VirtioVsock = null,
    blk: ?*vblk_mod.VirtioBlk = null,
    net: ?*vnet_mod.VirtioNet = null,

    pub fn isMmioAddr(addr: u32) bool {
        return (addr >= MMIO_UART_BASE and
            addr < MMIO_UART_BASE + MMIO_UART_SIZE) or
            (addr >= MMIO_VIRTIO_BASE and addr < MMIO_VIRTIO_END) or
            (addr >= MMIO_CLINT_BASE and
                addr < MMIO_CLINT_BASE + MMIO_CLINT_SIZE) or
            (addr >= MMIO_PLIC_BASE and addr < MMIO_PLIC_END) or
            (addr >= MMIO_TEST_RTC_BASE and addr < MMIO_TEST_RTC_END);
    }

    pub fn isMmio(self: *const Bus, addr: u32) bool {
        _ = self;
        return isMmioAddr(addr);
    }

    pub fn read(self: *Bus, addr: u32, size: u8) u32 {
        _ = size;
        if (addr >= MMIO_UART_BASE and
            addr < MMIO_UART_BASE + MMIO_UART_SIZE)
        {
            const val = self.uart.read(@truncate(addr - MMIO_UART_BASE));
            _ = self.syncDeviceIrqs();
            return val;
        } else if (addr >= MMIO_VIRTIO_BASE and addr < MMIO_VIRTIO_END) {
            const slot_idx = (addr - MMIO_VIRTIO_BASE) / VIRTIO_SLOT_STRIDE;
            const reg_offset =
                (addr - MMIO_VIRTIO_BASE) & VIRTIO_SLOT_OFFSET_MASK;
            if (slot_idx == VIRTIO_SLOT_VSOCK) {
                if (self.vsock) |v| return v.readReg(reg_offset);
            } else if (slot_idx == VIRTIO_SLOT_BLK) {
                if (self.blk) |b| return b.readReg(reg_offset);
            } else if (slot_idx == VIRTIO_SLOT_NET) {
                if (self.net) |n| return n.readReg(reg_offset);
            }
            return switch (reg_offset) {
                VIRTIO_MMIO_REG_MAGIC_VALUE => VIRTIO_MMIO_MAGIC,
                VIRTIO_MMIO_REG_VERSION => VIRTIO_MMIO_VERSION_2,
                VIRTIO_MMIO_REG_DEVICE_ID => VIRTIO_MMIO_DEVICE_NONE,
                VIRTIO_MMIO_REG_VENDOR_ID => VIRTIO_MMIO_VENDOR_QEMU,
                else => 0,
            };
        } else if (addr >= MMIO_CLINT_BASE and
            addr < MMIO_CLINT_BASE + MMIO_CLINT_SIZE)
        {
            return self.timer.read(@truncate(addr - MMIO_CLINT_BASE));
        } else if (addr >= MMIO_PLIC_BASE and addr < MMIO_PLIC_END) {
            return self.pic.read(@truncate(addr - MMIO_PLIC_BASE));
        } else if (addr >= MMIO_RTC_BASE and addr < MMIO_TEST_RTC_END) {
            // Goldfish RTC: 0x00 = TIME_LOW, 0x04 = TIME_HIGH (ns).
            const reg_offset = addr & VIRTIO_SLOT_OFFSET_MASK;
            const time_ns: u64 = vcpu_mod.readHostTime() *% RTC_TICKS_TO_NS;
            if (reg_offset == RTC_TIME_LOW) return @truncate(time_ns);
            if (reg_offset == RTC_TIME_HIGH) {
                return @truncate(time_ns >> HIGH_WORD_SHIFT);
            }
            return 0;
        }
        return 0;
    }

    fn syncIrqLine(self: *Bus, irq: u32, active: bool) void {
        if (active) self.pic.setPending(irq) else self.pic.clearPending(irq);
    }

    pub fn syncDeviceIrqs(self: *Bus) bool {
        self.syncIrqLine(IRQ_UART0, self.uart.hasPendingIrq());
        if (self.vsock) |v| {
            self.syncIrqLine(
                IRQ_VIRTIO_VSOCK,
                @atomicLoad(u32, &v.interrupt_status, .seq_cst) != 0,
            );
        }
        if (self.blk) |b| {
            self.syncIrqLine(
                IRQ_VIRTIO_BLK,
                @atomicLoad(u32, &b.interrupt_status, .seq_cst) != 0,
            );
        }
        if (self.net) |n| {
            self.syncIrqLine(
                IRQ_VIRTIO_NET,
                @atomicLoad(u32, &n.interrupt_status, .seq_cst) != 0,
            );
        }
        return self.pic.hasDeliverableIrq();
    }

    pub fn write(self: *Bus, addr: u32, val: u32, _: u8) void {
        if (addr >= MMIO_UART_BASE and
            addr < MMIO_UART_BASE + MMIO_UART_SIZE)
        {
            self.uart.write(@truncate(addr - MMIO_UART_BASE), @truncate(val));
            _ = self.syncDeviceIrqs();
        } else if (addr >= MMIO_VIRTIO_BASE and addr < MMIO_VIRTIO_END) {
            const slot_idx = (addr - MMIO_VIRTIO_BASE) / VIRTIO_SLOT_STRIDE;
            const reg_offset =
                (addr - MMIO_VIRTIO_BASE) & VIRTIO_SLOT_OFFSET_MASK;
            if (slot_idx == VIRTIO_SLOT_VSOCK) {
                if (self.vsock) |v| v.writeReg(reg_offset, val);
            } else if (slot_idx == VIRTIO_SLOT_BLK) {
                if (self.blk) |b| b.writeReg(reg_offset, val);
            } else if (slot_idx == VIRTIO_SLOT_NET) {
                if (self.net) |n| n.writeReg(reg_offset, val);
            }
            _ = self.syncDeviceIrqs();
        } else if (addr >= MMIO_CLINT_BASE and
            addr < MMIO_CLINT_BASE + MMIO_CLINT_SIZE)
        {
            self.timer.write(@truncate(addr - MMIO_CLINT_BASE), val);
        } else if (addr >= MMIO_PLIC_BASE and addr < MMIO_PLIC_END) {
            self.pic.write(@truncate(addr - MMIO_PLIC_BASE), val);
        } else if (addr >= MMIO_TEST_RTC_BASE and addr < MMIO_TEST_RTC_END) {
            // Test & Goldfish RTC writes are no-ops.
        }
    }
};

test "MMIO Bus address classification and VirtIO transport probe" {
    const testing = std.testing;
    const eq = testing.expectEqual;
    testing.refAllDecls(@This());
    _ = .{ vsock_mod, vblk_mod, vnet_mod };

    for ([_]u32{
        0x10000000, 0x10001000, 0x10002000, 0x10003000,
        0x02000000, 0x0c000000, 0x00101000,
    }) |addr| try testing.expect(Bus.isMmioAddr(addr));
    try testing.expect(!Bus.isMmioAddr(0x80000000));

    var uart = vuart_mod.VirtualUart{};
    var timer = vtimer_mod.VirtualTimer{};
    var pic = vpic_mod.VirtualPlic{};
    var vsock = vsock_mod.VirtioVsock{};
    var net = vnet_mod.VirtioNet{};
    var bus = Bus{
        .uart = &uart,
        .timer = &timer,
        .pic = &pic,
        .vsock = &vsock,
        .net = &net,
    };

    try eq(VIRTIO_MMIO_MAGIC, bus.read(MMIO_VIRTIO_BASE + 0x000, 4));
    try eq(VIRTIO_MMIO_VERSION_2, bus.read(MMIO_VIRTIO_BASE + 0x004, 4));
    try eq(VIRTIO_MMIO_DEVICE_NONE, bus.read(MMIO_VIRTIO_BASE + 0x1008, 4));
    try testing.expect(
        bus.read(MMIO_VIRTIO_BASE + 0x008, 4) != VIRTIO_MMIO_DEVICE_NONE,
    );
    try testing.expect(
        bus.read(MMIO_VIRTIO_BASE + 0x4008, 4) != VIRTIO_MMIO_DEVICE_NONE,
    );
    try eq(
        @as(u64, VIRTIO_MMIO_REG_SHM_NONE),
        bus.read(MMIO_VIRTIO_BASE + VIRTIO_MMIO_REG_SHM_LEN_LOW, 4),
    );
}
