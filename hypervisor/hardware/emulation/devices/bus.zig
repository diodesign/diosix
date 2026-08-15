// Memory Mapped I/O (MMIO) Bus Router for Diosix Virtual Devices
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const vuart_mod = @import("vuart.zig");
const vtimer_mod = @import("vtimer.zig");
const vpic_mod = @import("vpic.zig");

pub const Bus = struct {
    uart: *vuart_mod.VirtualUart,
    timer: *vtimer_mod.VirtualTimer,
    pic: *vpic_mod.VirtualPlic,

    pub fn isMmioAddr(addr: u32) bool {
        if (addr >= 0x10000000 and addr < 0x10000100) return true; // 16550 UART
        if (addr >= 0x02000000 and addr < 0x02010000) return true; // CLINT Timer
        if (addr >= 0x0c000000 and addr < 0x10000000) return true; // PLIC
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
        } else if (addr >= 0x02000000 and addr < 0x02010000) {
            return self.timer.read(@truncate(addr - 0x02000000));
        } else if (addr >= 0x0c000000 and addr < 0x10000000) {
            return self.pic.read(@truncate(addr - 0x0c000000));
        }
        return 0;
    }

    pub fn write(self: *Bus, addr: u32, val: u32, size: u8) void {
        _ = size;
        if (addr >= 0x10000000 and addr < 0x10000100) {
            self.uart.write(@truncate(addr - 0x10000000), @truncate(val));
        } else if (addr >= 0x02000000 and addr < 0x02010000) {
            self.timer.write(@truncate(addr - 0x02000000), val);
        } else if (addr >= 0x0c000000 and addr < 0x10000000) {
            self.pic.write(@truncate(addr - 0x0c000000), val);
        }
    }
};
