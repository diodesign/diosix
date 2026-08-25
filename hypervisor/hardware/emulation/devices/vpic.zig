// Virtual PLIC Interrupt Controller Model for Emulated Guests
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub const MAX_CONTEXTS: usize = 8;
pub const MAX_IRQS: usize = 128; // Standard QEMU virt PLIC has 96 IRQs (indices 1..96)

pub const BITS_PER_WORD: usize = 32;
pub const BYTES_PER_WORD: u32  = 4;

pub const PLIC_PRIORITY_BASE: u32      = 0x0000;
pub const PLIC_PENDING_BASE: u32       = 0x1000;
pub const PLIC_ENABLE_BASE: u32        = 0x2000;
pub const PLIC_ENABLE_CTX_STRIDE: u32  = 0x80;
pub const PLIC_CONTEXT_BASE: u32       = 0x200000;
pub const PLIC_CONTEXT_STRIDE: u32     = 0x1000;

pub const PLIC_REG_THRESHOLD: u32      = 0;
pub const PLIC_REG_CLAIM_COMPLETE: u32 = 4;

pub const VirtualPlic = struct {
    priority: [MAX_IRQS]u32 = std.mem.zeroes([MAX_IRQS]u32),
    pending: [MAX_IRQS / BITS_PER_WORD]u32 = std.mem.zeroes([MAX_IRQS / BITS_PER_WORD]u32),
    enable: [MAX_CONTEXTS][MAX_IRQS / BITS_PER_WORD]u32 = std.mem.zeroes([MAX_CONTEXTS][MAX_IRQS / BITS_PER_WORD]u32),
    threshold: [MAX_CONTEXTS]u32 = std.mem.zeroes([MAX_CONTEXTS]u32),
    claimed_irq: [MAX_CONTEXTS]u32 = std.mem.zeroes([MAX_CONTEXTS]u32),

    pub fn setPending(self: *VirtualPlic, irq: u32) void {
        if (irq > 0 and irq < MAX_IRQS) {
            const word_idx = irq / BITS_PER_WORD;
            const bit_idx: u5 = @truncate(irq % BITS_PER_WORD);
            self.pending[word_idx] |= (@as(u32, 1) << bit_idx);
        }
    }

    pub fn clearPending(self: *VirtualPlic, irq: u32) void {
        if (irq > 0 and irq < MAX_IRQS) {
            const word_idx = irq / BITS_PER_WORD;
            const bit_idx: u5 = @truncate(irq % BITS_PER_WORD);
            self.pending[word_idx] &= ~(@as(u32, 1) << bit_idx);
        }
    }

    pub fn read(self: *VirtualPlic, offset: u32) u32 {
        // Source Priorities: 0x0000 .. 0x01FC (up to 128 IRQs)
        if (offset < (MAX_IRQS * BYTES_PER_WORD)) {
            const irq = offset / BYTES_PER_WORD;
            return self.priority[irq];
        }

        // Pending Bits: 0x1000 .. 0x100C (4 words = 128 IRQs)
        if (offset >= PLIC_PENDING_BASE and offset < PLIC_PENDING_BASE + ((MAX_IRQS / BITS_PER_WORD) * BYTES_PER_WORD)) {
            const word_idx = (offset - PLIC_PENDING_BASE) / BYTES_PER_WORD;
            return self.pending[word_idx];
        }

        // Enable Bits: 0x2000 + ctx * 0x80 (each context has 4 words)
        if (offset >= PLIC_ENABLE_BASE and offset < PLIC_ENABLE_BASE + (MAX_CONTEXTS * PLIC_ENABLE_CTX_STRIDE)) {
            const rel = offset - PLIC_ENABLE_BASE;
            const ctx = rel / PLIC_ENABLE_CTX_STRIDE;
            const word_idx = (rel % PLIC_ENABLE_CTX_STRIDE) / BYTES_PER_WORD;
            if (ctx < MAX_CONTEXTS and word_idx < (MAX_IRQS / BITS_PER_WORD)) {
                return self.enable[ctx][word_idx];
            }
        }

        // Context Priority Threshold & Claim/Complete: 0x200000 + ctx * 0x1000
        if (offset >= PLIC_CONTEXT_BASE and offset < PLIC_CONTEXT_BASE + (MAX_CONTEXTS * PLIC_CONTEXT_STRIDE)) {
            const rel = offset - PLIC_CONTEXT_BASE;
            const ctx = rel / PLIC_CONTEXT_STRIDE;
            const reg = rel & 0xFFF;
            if (ctx < MAX_CONTEXTS) {
                if (reg == PLIC_REG_THRESHOLD) {
                    return self.threshold[ctx];
                } else if (reg == PLIC_REG_CLAIM_COMPLETE) {
                    // Claim: return the highest-priority pending interrupt for this context
                    var best_irq: u32 = 0;
                    var best_prio: u32 = self.threshold[ctx];

                    for (1..MAX_IRQS) |irq_usize| {
                        const irq: u32 = @truncate(irq_usize);
                        const word_idx = irq / BITS_PER_WORD;
                        const bit_idx: u5 = @truncate(irq % BITS_PER_WORD);
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
        if (offset < (MAX_IRQS * BYTES_PER_WORD)) {
            const irq = offset / BYTES_PER_WORD;
            self.priority[irq] = val;
        } else if (offset >= PLIC_ENABLE_BASE and offset < PLIC_ENABLE_BASE + (MAX_CONTEXTS * PLIC_ENABLE_CTX_STRIDE)) {
            const rel = offset - PLIC_ENABLE_BASE;
            const ctx = rel / PLIC_ENABLE_CTX_STRIDE;
            const word_idx = (rel % PLIC_ENABLE_CTX_STRIDE) / BYTES_PER_WORD;
            if (ctx < MAX_CONTEXTS and word_idx < (MAX_IRQS / BITS_PER_WORD)) {
                self.enable[ctx][word_idx] = val;
            }
        } else if (offset >= PLIC_CONTEXT_BASE and offset < PLIC_CONTEXT_BASE + (MAX_CONTEXTS * PLIC_CONTEXT_STRIDE)) {
            const rel = offset - PLIC_CONTEXT_BASE;
            const ctx = rel / PLIC_CONTEXT_STRIDE;
            const reg = rel & 0xFFF;
            if (ctx < MAX_CONTEXTS) {
                if (reg == PLIC_REG_THRESHOLD) {
                    self.threshold[ctx] = val;
                } else if (reg == PLIC_REG_CLAIM_COMPLETE) {
                    // Complete: reset the claimed state for this context
                    self.claimed_irq[ctx] = 0;
                }
            }
        }
    }
};

test "PLIC interrupt priority, enable, pending, claim and complete" {
    const testing = std.testing;

    var plic = VirtualPlic{};

    // 1. Configure IRQ 10 priority = 5, IRQ 11 priority = 7
    plic.write(10 * BYTES_PER_WORD, 5);
    plic.write(11 * BYTES_PER_WORD, 7);
    try testing.expectEqual(@as(u32, 5), plic.read(10 * BYTES_PER_WORD));
    try testing.expectEqual(@as(u32, 7), plic.read(11 * BYTES_PER_WORD));

    // 2. Enable IRQ 10 and 11 on context 0 (word 0: bits 10 and 11)
    const ctx0_enable_addr = PLIC_ENABLE_BASE + (0 * PLIC_ENABLE_CTX_STRIDE);
    plic.write(ctx0_enable_addr, (1 << 10) | (1 << 11));
    try testing.expectEqual(@as(u32, (1 << 10) | (1 << 11)), plic.read(ctx0_enable_addr));

    // 3. Set Context 0 Priority Threshold = 6 (blocks IRQ 10 prio 5, allows IRQ 11 prio 7)
    const ctx0_threshold_addr = PLIC_CONTEXT_BASE + (0 * PLIC_CONTEXT_STRIDE) + PLIC_REG_THRESHOLD;
    plic.write(ctx0_threshold_addr, 6);
    try testing.expectEqual(@as(u32, 6), plic.read(ctx0_threshold_addr));

    // 4. Assert IRQ 10 only -> claim should return 0 because priority 5 <= threshold 6
    plic.setPending(10);
    const ctx0_claim_addr = PLIC_CONTEXT_BASE + (0 * PLIC_CONTEXT_STRIDE) + PLIC_REG_CLAIM_COMPLETE;
    try testing.expectEqual(@as(u32, 0), plic.read(ctx0_claim_addr));

    // 5. Assert IRQ 11 -> claim should return 11 (priority 7 > threshold 6) and auto-clear pending
    plic.setPending(11);
    try testing.expectEqual(@as(u32, 11), plic.read(ctx0_claim_addr));
    try testing.expectEqual(@as(u32, 11), plic.claimed_irq[0]);

    // 6. Complete IRQ 11
    plic.write(ctx0_claim_addr, 11);
    try testing.expectEqual(@as(u32, 0), plic.claimed_irq[0]);
}


