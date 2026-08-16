// Memory Mapped I/O (MMIO) Bus Router for Diosix Virtual Devices
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const vuart_mod = @import("vuart.zig");
const vtimer_mod = @import("vtimer.zig");
const vpic_mod = @import("vpic.zig");
const vcpu_mod = @import("../vcpu.zig");

pub const Bus = struct {
    uart: *vuart_mod.VirtualUart,
    timer: *vtimer_mod.VirtualTimer,
    pic: *vpic_mod.VirtualPlic,

    pub fn isMmioAddr(addr: u32) bool {
        if (addr >= 0x10000000 and addr < 0x10000100) return true; // 16550 UART
        if (addr >= 0x10001000 and addr < 0x10009000) return true; // VirtIO MMIO slots 0..7
        if (addr >= 0x02000000 and addr < 0x02010000) return true; // CLINT Timer
        if (addr >= 0x0c000000 and addr < 0x10000000) return true; // PLIC
        if (addr >= 0x00100000 and addr < 0x00102000) return true; // Test & Goldfish RTC
        return false;
    }

    pub fn isMmio(self: *const Bus, addr: u32) bool {
        _ = self;
        return isMmioAddr(addr);
    }

    pub fn read(self: *Bus, addr: u32, size: u8) u32 {
        _ = size;
        if (addr >= 0x10000000 and addr < 0x10000100) {
            return self.uart.read(@truncate(addr - 0x10000000));
        } else if (addr >= 0x10001000 and addr < 0x10009000) {
            // VirtIO MMIO transport probe
            const reg_offset = (addr - 0x10001000) & 0xFFF;
            return switch (reg_offset) {
                0x000 => 0x74726976, // MagicValue: "virt" in little-endian (0x74726976)
                0x004 => 0x00000002, // Version: 2 (Modern VirtIO)
                0x008 => 0x00000000, // DeviceID: 0 (No device connected / empty slot)
                0x00c => 0x554d4551, // VendorID: "QEMU" in ASCII
                else => 0,
            };
        } else if (addr >= 0x02000000 and addr < 0x02010000) {
            return self.timer.read(@truncate(addr - 0x02000000));
        } else if (addr >= 0x0c000000 and addr < 0x10000000) {
            return self.pic.read(@truncate(addr - 0x0c000000));
        } else if (addr >= 0x00101000 and addr < 0x00102000) {
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
        if (addr >= 0x10000000 and addr < 0x10000100) {
            self.uart.write(@truncate(addr - 0x10000000), @truncate(val));
        } else if (addr >= 0x10001000 and addr < 0x10009000) {
            // Read-only configuration or control writes for empty slots are ignored
        } else if (addr >= 0x02000000 and addr < 0x02010000) {
            self.timer.write(@truncate(addr - 0x02000000), val);
        } else if (addr >= 0x0c000000 and addr < 0x10000000) {
            self.pic.write(@truncate(addr - 0x0c000000), val);
        } else if (addr >= 0x00100000 and addr < 0x00102000) {
            // Test & Goldfish RTC writes
        }
    }
};
