// Virtual PLIC Interrupt Controller Model for Emulated Guests
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub const STATIC_CONTEXTS: usize = 32;
pub const DYNAMIC_HASH_BUCKETS: usize = 32;
pub const MAX_SYSTEM_CONTEXTS: usize = 15872;
pub const MAX_CONTEXTS: usize = MAX_SYSTEM_CONTEXTS;
pub const MAX_IRQS: usize = 128; // Standard QEMU virt PLIC has 96 IRQs (indices 1..96)

pub const BITS_PER_WORD: usize = 32;
pub const BYTES_PER_WORD: u32 = 4;

pub const PLIC_PRIORITY_BASE: u32 = 0x0000;
pub const PLIC_PENDING_BASE: u32 = 0x1000;
pub const PLIC_ENABLE_BASE: u32 = 0x2000;
pub const PLIC_ENABLE_CTX_STRIDE: u32 = 0x80;
pub const PLIC_CONTEXT_BASE: u32 = 0x200000;
pub const PLIC_CONTEXT_STRIDE: u32 = 0x1000;

pub const PLIC_REG_THRESHOLD: u32 = 0;
pub const PLIC_REG_CLAIM_COMPLETE: u32 = 4;

pub const PlicContext = struct {
    context_id: usize = 0,
    enable: [MAX_IRQS / BITS_PER_WORD]u32 = @splat(0),
    threshold: u32 = 0,
    claimed_irq: u32 = 0,
    next: ?*PlicContext = null,
};

pub const VirtualPlic = struct {
    priority: [MAX_IRQS]u32 = std.mem.zeroes([MAX_IRQS]u32),
    pending: [MAX_IRQS / BITS_PER_WORD]u32 = std.mem.zeroes([MAX_IRQS / BITS_PER_WORD]u32),

    // Column 1: Static fast-path contexts 0..31 (wait-free, O(1), zero heap allocation)
    static_contexts: [STATIC_CONTEXTS]PlicContext = @splat(.{}),
    // Column 2: Dynamic hash buckets for contexts >= 32 (keyed by ctx % 32)
    dynamic_buckets: [DYNAMIC_HASH_BUCKETS]?*PlicContext = @splat(null),
    // Embedded pool for dynamic contexts when standalone or pre-heap (up to 128 dynamic contexts = 160 total contexts = 80 harts)
    dynamic_pool: [128]PlicContext = @splat(.{}),
    pool_count: usize = 0,
    lock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn getContext(self: *VirtualPlic, ctx: usize, create_if_missing: bool) ?*PlicContext {
        if (ctx < STATIC_CONTEXTS) {
            return &self.static_contexts[ctx];
        }
        if (ctx >= MAX_SYSTEM_CONTEXTS) return null;

        while (self.lock.swap(true, .acquire)) {
            std.atomic.spinLoopHint();
        }
        defer self.lock.store(false, .release);

        const bucket = ctx % DYNAMIC_HASH_BUCKETS;
        var curr = self.dynamic_buckets[bucket];
        while (curr) |node| {
            if (node.context_id == ctx) return node;
            curr = node.next;
        }
        if (create_if_missing) {
            if (self.pool_count < self.dynamic_pool.len) {
                const node = &self.dynamic_pool[self.pool_count];
                self.pool_count += 1;
                node.* = .{
                    .context_id = ctx,
                    .enable = @splat(0),
                    .threshold = 0,
                    .claimed_irq = 0,
                    .next = self.dynamic_buckets[bucket],
                };
                self.dynamic_buckets[bucket] = node;
                return node;
            }
        }
        return null;
    }

    pub fn getContextConst(self: *const VirtualPlic, ctx: usize) ?*const PlicContext {
        if (ctx < STATIC_CONTEXTS) {
            return &self.static_contexts[ctx];
        }
        if (ctx >= MAX_SYSTEM_CONTEXTS) return null;

        const mutable_self: *VirtualPlic = @constCast(self);
        while (mutable_self.lock.swap(true, .acquire)) {
            std.atomic.spinLoopHint();
        }
        defer mutable_self.lock.store(false, .release);

        const bucket = ctx % DYNAMIC_HASH_BUCKETS;
        var curr = self.dynamic_buckets[bucket];
        while (curr) |node| {
            if (node.context_id == ctx) return node;
            curr = node.next;
        }
        return null;
    }

    pub fn reset(self: *VirtualPlic) void {
        while (self.lock.swap(true, .acquire)) {
            std.atomic.spinLoopHint();
        }
        defer self.lock.store(false, .release);

        self.priority = std.mem.zeroes([MAX_IRQS]u32);
        self.pending = std.mem.zeroes([MAX_IRQS / BITS_PER_WORD]u32);
        self.static_contexts = @splat(.{});
        self.dynamic_buckets = @splat(null);
        self.dynamic_pool = @splat(.{});
        self.pool_count = 0;
    }

    pub fn getClaimedIrq(self: *const VirtualPlic, ctx: usize) u32 {
        if (self.getContextConst(ctx)) |c| return c.claimed_irq;
        return 0;
    }

    pub fn setPending(self: *VirtualPlic, irq: u32) void {
        if (irq > 0 and irq < MAX_IRQS) {
            const word_idx = irq / BITS_PER_WORD;
            const bit_idx: u5 = @truncate(irq % BITS_PER_WORD);
            _ = @atomicRmw(u32, &self.pending[word_idx], .Or, (@as(u32, 1) << bit_idx), .acq_rel);
        }
    }

    pub fn testAndClearPending(self: *VirtualPlic, irq: u32) bool {
        if (irq > 0 and irq < MAX_IRQS) {
            const word_idx = irq / BITS_PER_WORD;
            const bit_idx: u5 = @truncate(irq % BITS_PER_WORD);
            const mask = @as(u32, 1) << bit_idx;
            const prev = @atomicRmw(u32, &self.pending[word_idx], .And, ~mask, .acq_rel);
            return (prev & mask) != 0;
        }
        return false;
    }

    pub fn clearPending(self: *VirtualPlic, irq: u32) void {
        _ = self.testAndClearPending(irq);
    }

    pub fn read(self: *VirtualPlic, offset: u32) u32 {
        if ((offset % BYTES_PER_WORD) != 0) return 0;

        // Source Priorities: 0x0000 .. 0x01FC (up to 128 IRQs)
        if (offset < (MAX_IRQS * BYTES_PER_WORD)) {
            const irq = offset / BYTES_PER_WORD;
            if (irq == 0) return 0; // IRQ 0 priority is hardwired to 0 per RISC-V PLIC spec
            return self.priority[irq];
        }

        // Pending Bits: 0x1000 .. 0x100C (4 words = 128 IRQs)
        if (offset >= PLIC_PENDING_BASE and offset < PLIC_PENDING_BASE + ((MAX_IRQS / BITS_PER_WORD) * BYTES_PER_WORD)) {
            const word_idx = (offset - PLIC_PENDING_BASE) / BYTES_PER_WORD;
            return self.pending[word_idx];
        }

        // Enable Bits: 0x2000 + ctx * 0x80 (each context has 4 words)
        if (offset >= PLIC_ENABLE_BASE and offset < PLIC_CONTEXT_BASE) {
            const rel = offset - PLIC_ENABLE_BASE;
            const ctx = rel / PLIC_ENABLE_CTX_STRIDE;
            const word_idx = (rel % PLIC_ENABLE_CTX_STRIDE) / BYTES_PER_WORD;
            if (word_idx < (MAX_IRQS / BITS_PER_WORD)) {
                if (self.getContext(ctx, false)) |c| {
                    return c.enable[word_idx];
                }
            }
            return 0;
        }

        // Context Priority Threshold & Claim/Complete: 0x200000 + ctx * 0x1000
        if (offset >= PLIC_CONTEXT_BASE) {
            const rel = offset - PLIC_CONTEXT_BASE;
            const ctx = rel / PLIC_CONTEXT_STRIDE;
            const reg = rel & 0xFFF;
            if (self.getContext(ctx, false)) |c| {
                if (reg == PLIC_REG_THRESHOLD) {
                    return c.threshold;
                } else if (reg == PLIC_REG_CLAIM_COMPLETE) {
                    // Claim: return the highest-priority pending interrupt for this context
                    var best_irq: u32 = 0;
                    var best_prio: u32 = c.threshold;

                    for (1..MAX_IRQS) |irq_usize| {
                        const irq: u32 = @truncate(irq_usize);
                        const word_idx = irq / BITS_PER_WORD;
                        const bit_idx: u5 = @truncate(irq % BITS_PER_WORD);
                        const is_en = (c.enable[word_idx] & (@as(u32, 1) << bit_idx)) != 0;
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
                        if (self.testAndClearPending(best_irq)) {
                            c.claimed_irq = best_irq;
                            return best_irq;
                        }
                    }
                    return 0;
                }
            }
        }
        return 0;
    }

    pub fn write(self: *VirtualPlic, offset: u32, val: u32) void {
        if ((offset % BYTES_PER_WORD) != 0) return;

        // Source Priorities
        if (offset < (MAX_IRQS * BYTES_PER_WORD)) {
            const irq = offset / BYTES_PER_WORD;
            if (irq == 0) return; // IRQ 0 priority is hardwired to 0 (read-only)
            self.priority[irq] = val;
        } else if (offset >= PLIC_ENABLE_BASE and offset < PLIC_CONTEXT_BASE) {
            const rel = offset - PLIC_ENABLE_BASE;
            const ctx = rel / PLIC_ENABLE_CTX_STRIDE;
            const word_idx = (rel % PLIC_ENABLE_CTX_STRIDE) / BYTES_PER_WORD;
            if (word_idx < (MAX_IRQS / BITS_PER_WORD)) {
                if (self.getContext(ctx, true)) |c| {
                    // In context enable word 0, bit 0 is reserved/hardwired to 0 (no IRQ 0)
                    const effective_val = if (word_idx == 0) val & ~@as(u32, 1) else val;
                    c.enable[word_idx] = effective_val;
                }
            }
        } else if (offset >= PLIC_CONTEXT_BASE) {
            const rel = offset - PLIC_CONTEXT_BASE;
            const ctx = rel / PLIC_CONTEXT_STRIDE;
            const reg = rel & 0xFFF;
            if (self.getContext(ctx, true)) |c| {
                if (reg == PLIC_REG_THRESHOLD) {
                    c.threshold = val;
                } else if (reg == PLIC_REG_CLAIM_COMPLETE) {
                    // Complete: reset the claimed state for this context if the written IRQ matches
                    if (val != 0 and val == c.claimed_irq) {
                        c.claimed_irq = 0;
                    }
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
    try testing.expectEqual(@as(u32, 11), plic.getClaimedIrq(0));

    // 6a. Attempt to complete with mismatched IRQ (e.g. 5 or 0) -> should be rejected/ignored
    plic.write(ctx0_claim_addr, 5);
    try testing.expectEqual(@as(u32, 11), plic.getClaimedIrq(0));
    plic.write(ctx0_claim_addr, 0);
    try testing.expectEqual(@as(u32, 11), plic.getClaimedIrq(0));

    // 6b. Complete IRQ 11 with matching value -> clears claimed state
    plic.write(ctx0_claim_addr, 11);
    try testing.expectEqual(@as(u32, 0), plic.getClaimedIrq(0));

    // 7. Verify IRQ 0 priority is hardwired to 0 and writes are ignored
    plic.write(0, 99);
    try testing.expectEqual(@as(u32, 0), plic.read(0));

    // 8. Verify context enable word 0 bit 0 (IRQ 0) is hardwired to 0
    plic.write(ctx0_enable_addr, 0xFFFFFFFF);
    try testing.expectEqual(@as(u32, 0xFFFFFFFE), plic.read(ctx0_enable_addr));

    // 9. Verify unaligned register reads and writes are rejected
    try testing.expectEqual(@as(u32, 0), plic.read(10 * BYTES_PER_WORD + 1));
    plic.write(10 * BYTES_PER_WORD + 1, 999);
    try testing.expectEqual(@as(u32, 5), plic.read(10 * BYTES_PER_WORD)); // Still original priority 5

    // 10. Verify high context support up to context 31 (Hart 15 S-mode)
    const ctx31_enable_addr = PLIC_ENABLE_BASE + (31 * PLIC_ENABLE_CTX_STRIDE);
    const ctx31_threshold_addr = PLIC_CONTEXT_BASE + (31 * PLIC_CONTEXT_STRIDE) + PLIC_REG_THRESHOLD;
    const ctx31_claim_addr = PLIC_CONTEXT_BASE + (31 * PLIC_CONTEXT_STRIDE) + PLIC_REG_CLAIM_COMPLETE;

    plic.write(ctx31_enable_addr, 1 << 10);
    try testing.expectEqual(@as(u32, 1 << 10), plic.read(ctx31_enable_addr));

    plic.write(ctx31_threshold_addr, 4); // Priority 5 > threshold 4
    try testing.expectEqual(@as(u32, 4), plic.read(ctx31_threshold_addr));

    plic.setPending(10);
    try testing.expectEqual(@as(u32, 10), plic.read(ctx31_claim_addr));
    try testing.expectEqual(@as(u32, 10), plic.getClaimedIrq(31));

    plic.write(ctx31_claim_addr, 10);
    try testing.expectEqual(@as(u32, 0), plic.getClaimedIrq(31));

    // 11. Verify dynamic context support for contexts >= 32 (Column 2 dynamic hash buckets)
    const ctx32_enable_addr = PLIC_ENABLE_BASE + (32 * PLIC_ENABLE_CTX_STRIDE);
    const ctx32_threshold_addr = PLIC_CONTEXT_BASE + (32 * PLIC_CONTEXT_STRIDE) + PLIC_REG_THRESHOLD;
    const ctx32_claim_addr = PLIC_CONTEXT_BASE + (32 * PLIC_CONTEXT_STRIDE) + PLIC_REG_CLAIM_COMPLETE;

    plic.write(ctx32_enable_addr, 1 << 11);
    try testing.expectEqual(@as(u32, 1 << 11), plic.read(ctx32_enable_addr));

    plic.write(ctx32_threshold_addr, 2);
    try testing.expectEqual(@as(u32, 2), plic.read(ctx32_threshold_addr));

    plic.setPending(11);
    try testing.expectEqual(@as(u32, 11), plic.read(ctx32_claim_addr));
    try testing.expectEqual(@as(u32, 11), plic.getClaimedIrq(32));

    plic.write(ctx32_claim_addr, 11);
    try testing.expectEqual(@as(u32, 0), plic.getClaimedIrq(32));

    // Dynamic Context 64 (Collides with 32 in bucket 0)
    const ctx64_enable_addr = PLIC_ENABLE_BASE + (64 * PLIC_ENABLE_CTX_STRIDE);
    const ctx64_threshold_addr = PLIC_CONTEXT_BASE + (64 * PLIC_CONTEXT_STRIDE) + PLIC_REG_THRESHOLD;
    const ctx64_claim_addr = PLIC_CONTEXT_BASE + (64 * PLIC_CONTEXT_STRIDE) + PLIC_REG_CLAIM_COMPLETE;

    plic.write(ctx64_enable_addr, 1 << 10);
    try testing.expectEqual(@as(u32, 1 << 10), plic.read(ctx64_enable_addr));

    plic.write(ctx64_threshold_addr, 1);
    try testing.expectEqual(@as(u32, 1), plic.read(ctx64_threshold_addr));

    plic.setPending(10);
    try testing.expectEqual(@as(u32, 10), plic.read(ctx64_claim_addr));
    try testing.expectEqual(@as(u32, 10), plic.getClaimedIrq(64));

    plic.write(ctx64_claim_addr, 10);
    try testing.expectEqual(@as(u32, 0), plic.getClaimedIrq(64));
}
