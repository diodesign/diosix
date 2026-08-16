// Virtual PLIC Interrupt Controller Model for Emulated Guests
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub const MAX_CONTEXTS: usize = 8;
pub const MAX_IRQS: usize = 128; // Standard QEMU virt PLIC has 96 IRQs (indices 1..96)

pub const VirtualPlic = struct {
    priority: [MAX_IRQS]u32 = std.mem.zeroes([MAX_IRQS]u32),
    pending: [MAX_IRQS / 32]u32 = std.mem.zeroes([MAX_IRQS / 32]u32),
    enable: [MAX_CONTEXTS][MAX_IRQS / 32]u32 = std.mem.zeroes([MAX_CONTEXTS][MAX_IRQS / 32]u32),
    threshold: [MAX_CONTEXTS]u32 = std.mem.zeroes([MAX_CONTEXTS]u32),
    claimed_irq: [MAX_CONTEXTS]u32 = std.mem.zeroes([MAX_CONTEXTS]u32),

    pub fn setPending(self: *VirtualPlic, irq: u32) void {
        if (irq > 0 and irq < MAX_IRQS) {
            const word_idx = irq / 32;
            const bit_idx: u5 = @truncate(irq % 32);
            self.pending[word_idx] |= (@as(u32, 1) << bit_idx);
        }
    }

    pub fn clearPending(self: *VirtualPlic, irq: u32) void {
        if (irq > 0 and irq < MAX_IRQS) {
            const word_idx = irq / 32;
            const bit_idx: u5 = @truncate(irq % 32);
            self.pending[word_idx] &= ~(@as(u32, 1) << bit_idx);
        }
    }

    pub fn read(self: *VirtualPlic, offset: u32) u32 {
        // Source Priorities: 0x0000 .. 0x01FC (up to 128 IRQs)
        if (offset < (MAX_IRQS * 4)) {
            const irq = offset >> 2;
            return self.priority[irq];
        }

        // Pending Bits: 0x1000 .. 0x100C (4 words = 128 IRQs)
        if (offset >= 0x1000 and offset < 0x1000 + ((MAX_IRQS / 32) * 4)) {
            const word_idx = (offset - 0x1000) >> 2;
            return self.pending[word_idx];
        }

        // Enable Bits: 0x2000 + ctx * 0x80 (each context has 4 words)
        if (offset >= 0x2000 and offset < 0x2000 + (MAX_CONTEXTS * 0x80)) {
            const rel = offset - 0x2000;
            const ctx = rel / 0x80;
            const word_idx = (rel % 0x80) >> 2;
            if (ctx < MAX_CONTEXTS and word_idx < (MAX_IRQS / 32)) {
                return self.enable[ctx][word_idx];
            }
        }

        // Context Priority Threshold & Claim/Complete: 0x200000 + ctx * 0x1000
        if (offset >= 0x200000 and offset < 0x200000 + (MAX_CONTEXTS * 0x1000)) {
            const rel = offset - 0x200000;
            const ctx = rel / 0x1000;
            const reg = rel & 0xFFF;
            if (ctx < MAX_CONTEXTS) {
                if (reg == 0) {
                    return self.threshold[ctx];
                } else if (reg == 4) {
                    // Claim: return the highest-priority pending interrupt for this context
                    var best_irq: u32 = 0;
                    var best_prio: u32 = self.threshold[ctx];

                    for (1..MAX_IRQS) |irq_usize| {
                        const irq: u32 = @truncate(irq_usize);
                        const word_idx = irq / 32;
                        const bit_idx: u5 = @truncate(irq % 32);
                        const is_en = (self.enable[ctx][word_idx] & (@as(u32, 1) << bit_idx)) != 0;
                        const is_pend = (self.pending[word_idx] & (@as(u32, 1) << bit_idx)) != 0;
                        if (is_en and is_pend) {
                            const prio = self.priority[irq];
                            if (prio > best_prio) {
                                best_prio = prio;
                                best_irq = irq;
                            }
                        }
                    }

                    if (best_irq != 0) {
                        self.clearPending(best_irq);
                        self.claimed_irq[ctx] = best_irq;
                    }
                    return best_irq;
                }
            }
        }
        return 0;
    }

    pub fn write(self: *VirtualPlic, offset: u32, val: u32) void {
        // Source Priorities
        if (offset < (MAX_IRQS * 4)) {
            const irq = offset >> 2;
            self.priority[irq] = val;
        } else if (offset >= 0x2000 and offset < 0x2000 + (MAX_CONTEXTS * 0x80)) {
            const rel = offset - 0x2000;
            const ctx = rel / 0x80;
            const word_idx = (rel % 0x80) >> 2;
            if (ctx < MAX_CONTEXTS and word_idx < (MAX_IRQS / 32)) {
                self.enable[ctx][word_idx] = val;
            }
        } else if (offset >= 0x200000 and offset < 0x200000 + (MAX_CONTEXTS * 0x1000)) {
            const rel = offset - 0x200000;
            const ctx = rel / 0x1000;
            const reg = rel & 0xFFF;
            if (ctx < MAX_CONTEXTS) {
                if (reg == 0) {
                    self.threshold[ctx] = val;
                } else if (reg == 4) {
                    // Complete: reset the claimed state for this context
                    self.claimed_irq[ctx] = 0;
                }
            }
        }
    }
};
