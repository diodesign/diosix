// Memory Mapped I/O (MMIO) Bus Router for Diosix Virtual Devices
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const vuart_mod = @import("vuart.zig");
const vtimer_mod = @import("vtimer.zig");
const vpic_mod = @import("vpic.zig");
const vsock_mod = @import("vsock.zig");
const vgpu_mod = @import("vgpu.zig");
const vinput_mod = @import("vinput.zig");
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

pub const VIRTIO_MMIO_MAGIC: u32 = 0x74726976; // "virt" in little-endian
pub const VIRTIO_MMIO_VERSION_2: u32 = 0x00000002; // Modern VirtIO
pub const VIRTIO_MMIO_DEVICE_NONE: u32 = 0x00000000; // Empty slot
pub const VIRTIO_MMIO_VENDOR_QEMU: u32 = 0x554d4551; // "QEMU"

pub const Bus = struct {
    uart: *vuart_mod.VirtualUart,
    timer: *vtimer_mod.VirtualTimer,
    pic: *vpic_mod.VirtualPlic,
    vsock: ?*vsock_mod.VirtioVsock = null,
    gpu: ?*vgpu_mod.VirtioGpu = null,
    input: ?*vinput_mod.VirtioInput = null,

    pub fn isMmioAddr(addr: u32) bool {
        if (addr >= MMIO_UART_BASE and addr < MMIO_UART_BASE + MMIO_UART_SIZE) return true; // 16550 UART
        if (addr >= MMIO_VIRTIO_BASE and addr < MMIO_VIRTIO_END) return true; // VirtIO MMIO slots 0..7
        if (addr >= MMIO_CLINT_BASE and addr < MMIO_CLINT_BASE + MMIO_CLINT_SIZE) return true; // CLINT Timer
        if (addr >= MMIO_PLIC_BASE and addr < MMIO_PLIC_END) return true; // PLIC
        if (addr >= MMIO_TEST_RTC_BASE and addr < MMIO_TEST_RTC_END) return true; // Test & Goldfish RTC
        return false;
    }

    pub fn isMmio(self: *const Bus, addr: u32) bool {
        _ = self;
        return isMmioAddr(addr);
    }

    pub fn read(self: *Bus, addr: u32, size: u8) u32 {
        _ = size;
        if (addr >= MMIO_UART_BASE and addr < MMIO_UART_BASE + MMIO_UART_SIZE) {
            return self.uart.read(@truncate(addr - MMIO_UART_BASE));
        } else if (addr >= MMIO_VIRTIO_BASE and addr < MMIO_VIRTIO_END) {
            const slot_idx = (addr - MMIO_VIRTIO_BASE) / 0x1000;
            const reg_offset = (addr - MMIO_VIRTIO_BASE) & 0xFFF;
            if (slot_idx == 0) {
                if (self.vsock) |v| {
                    return v.readReg(reg_offset);
                }
            } else if (slot_idx == 1) {
                if (self.gpu) |g| {
                    return g.readReg(reg_offset);
                }
            } else if (slot_idx == 2) {
                if (self.input) |i| {
                    return i.readReg(reg_offset);
                }
            }
            return switch (reg_offset) {
                0x000 => VIRTIO_MMIO_MAGIC,
                0x004 => VIRTIO_MMIO_VERSION_2,
                0x008 => VIRTIO_MMIO_DEVICE_NONE,
                0x00c => VIRTIO_MMIO_VENDOR_QEMU,
                else => 0,
            };
        } else if (addr >= MMIO_CLINT_BASE and addr < MMIO_CLINT_BASE + MMIO_CLINT_SIZE) {
            return self.timer.read(@truncate(addr - MMIO_CLINT_BASE));
        } else if (addr >= MMIO_PLIC_BASE and addr < MMIO_PLIC_END) {
            return self.pic.read(@truncate(addr - MMIO_PLIC_BASE));
        } else if (addr >= MMIO_RTC_BASE and addr < MMIO_TEST_RTC_END) {
            // Goldfish RTC: offset 0x00 = TIME_LOW, offset 0x04 = TIME_HIGH (nanoseconds since epoch)
            const reg_offset = addr & 0xFFF;
            const time_ns: u64 = vcpu_mod.readHostTime() *% 100;
            if (reg_offset == 0x00) return @truncate(time_ns);
            if (reg_offset == 0x04) return @truncate(time_ns >> 32);
            return 0;
        }
        return 0;
    }

    pub fn write(self: *Bus, addr: u32, val: u32, size: u8) void {
        _ = size;
        if (addr >= MMIO_UART_BASE and addr < MMIO_UART_BASE + MMIO_UART_SIZE) {
            self.uart.write(@truncate(addr - MMIO_UART_BASE), @truncate(val));
        } else if (addr >= MMIO_VIRTIO_BASE and addr < MMIO_VIRTIO_END) {
            const slot_idx = (addr - MMIO_VIRTIO_BASE) / 0x1000;
            const reg_offset = (addr - MMIO_VIRTIO_BASE) & 0xFFF;
            if (slot_idx == 0) {
                if (self.vsock) |v| {
                    v.writeReg(reg_offset, val);
                    return;
                }
            } else if (slot_idx == 1) {
                if (self.gpu) |g| {
                    g.writeReg(reg_offset, val);
                    return;
                }
            } else if (slot_idx == 2) {
                if (self.input) |i| {
                    i.writeReg(reg_offset, val);
                    return;
                }
            }
        } else if (addr >= MMIO_CLINT_BASE and addr < MMIO_CLINT_BASE + MMIO_CLINT_SIZE) {
            self.timer.write(@truncate(addr - MMIO_CLINT_BASE), val);
        } else if (addr >= MMIO_PLIC_BASE and addr < MMIO_PLIC_END) {
            self.pic.write(@truncate(addr - MMIO_PLIC_BASE), val);
        } else if (addr >= MMIO_TEST_RTC_BASE and addr < MMIO_TEST_RTC_END) {
            // Test & Goldfish RTC writes
        }
    }
};

test "MMIO Bus address classification and VirtIO transport probe" {
    const testing = std.testing;

    // Test MMIO range classification
    try testing.expect(Bus.isMmioAddr(0x10000000)); // UART
    try testing.expect(Bus.isMmioAddr(0x10001000)); // VirtIO slot 0 (vsock)
    try testing.expect(Bus.isMmioAddr(0x10002000)); // VirtIO slot 1 (gpu)
    try testing.expect(Bus.isMmioAddr(0x10003000)); // VirtIO slot 2 (input)
    try testing.expect(Bus.isMmioAddr(0x02000000)); // CLINT
    try testing.expect(Bus.isMmioAddr(0x0c000000)); // PLIC
    try testing.expect(Bus.isMmioAddr(0x00101000)); // RTC
    try testing.expect(!Bus.isMmioAddr(0x80000000)); // DRAM is not MMIO

    var uart = vuart_mod.VirtualUart{};
    var timer = vtimer_mod.VirtualTimer{};
    var pic = vpic_mod.VirtualPlic{};
    var gpu = vgpu_mod.VirtioGpu.init(1);
    var input = vinput_mod.VirtioInput.init(1);

    var bus = Bus{
        .uart = &uart,
        .timer = &timer,
        .pic = &pic,
        .gpu = &gpu,
        .input = &input,
    };

    // Test VirtIO probe headers on Slot 1 (GPU) and Slot 2 (Input)
    try testing.expectEqual(VIRTIO_MMIO_MAGIC, bus.read(MMIO_VIRTIO_BASE + 0x1000 + 0x000, 4));
    try testing.expectEqual(VIRTIO_MMIO_VERSION_2, bus.read(MMIO_VIRTIO_BASE + 0x1000 + 0x004, 4));
    try testing.expectEqual(vgpu_mod.VIRTIO_ID_GPU, bus.read(MMIO_VIRTIO_BASE + 0x1000 + 0x008, 4));

    try testing.expectEqual(vinput_mod.VIRTIO_ID_INPUT, bus.read(MMIO_VIRTIO_BASE + 0x2000 + 0x008, 4));
}
