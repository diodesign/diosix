// generic atomic routines for spinlocks and so on
//
// Copyright (c) 2024-2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const value = std.atomic.Value;
const ordering = std.builtin.AtomicOrder;

// primitives for atomically reading and writing boolean flags
pub fn writeBool(ptr: *bool, val: bool) void {
    @atomicStore(bool, ptr, val, ordering.seq_cst);
}

pub fn readBool(ptr: *bool) bool {
    return @atomicLoad(bool, ptr, ordering.seq_cst);
}

// MIE bit in mstatus (bit 3): controls M-mode global interrupt enable.
const MSTATUS_MIE: usize = 1 << 3;

// Disable M-mode interrupts and return previous mstatus value.
// This prevents deadlock when a timer interrupt fires while holding a lock.
// Only effective in M-mode — from S-mode, M-mode interrupts cannot be
// controlled, so we return 0 (no-op on restore).
inline fn disableInterrupts() usize {
    if (builtin.is_test) return 0;
    return asm volatile ("csrrci %[ret], mstatus, 0x8"
        : [ret] "=r" (-> usize),
    );
}

// Restore mstatus.MIE to its previous value.
inline fn restoreInterrupts(prev: usize) void {
    if (builtin.is_test) return;
    if (prev & MSTATUS_MIE != 0) {
        // MIE was set before — re-enable it
        asm volatile ("csrsi mstatus, 0x8");
    }
}

// basic blocking spinlock implementation with interrupt save/restore.
// Acquiring the lock disables M-mode interrupts to prevent re-entrant
// deadlock (e.g., timer interrupt handler trying to acquire a lock
// already held by the interrupted code on the same hart).
const SpinLock = struct {
    lock_value: value(u32),

    pub fn init() SpinLock {
        return SpinLock{ .lock_value = value(u32).init(0) };
    }

    // Acquire the lock, disabling interrupts first. Returns the
    // previous mstatus so interrupts can be restored on unlock.
    pub fn lock(self: *SpinLock) usize {
        const prev_mstatus = disableInterrupts();
        while (self.lock_value.swap(1, ordering.acq_rel) != 0) {
            // spin until we get the lock. avoid hw_pause (wfi) during early boot
            // to prevent cores from waiting for interrupts that aren't set up yet.
            std.atomic.spinLoopHint();
        }
        return prev_mstatus;
    }

    // release the lock and restore interrupt state
    pub fn unlock(self: *SpinLock, prev_mstatus: usize) void {
        self.lock_value.store(0, ordering.release);
        restoreInterrupts(prev_mstatus);
    }
};

// a basic blocking spinlock with a human-readable name for diagnostics
pub const NamedSpinLock = struct {
    name: []const u8,
    spinlock: SpinLock,

    // initialize a named spinlock, providing the name as a string
    pub fn init(name: []const u8) NamedSpinLock {
        return NamedSpinLock{ .name = name, .spinlock = SpinLock.init() };
    }

    // acquire this spinlock, blocking until it's available
    pub fn lock(self: *NamedSpinLock) usize {
        return self.spinlock.lock();
    }

    // release this spinlock so others can acquire it
    pub fn unlock(self: *NamedSpinLock, prev_mstatus: usize) void {
        self.spinlock.unlock(prev_mstatus);
    }
};

// LockPayload provides RAII-style mutual exclusion for any type T. It uses a
// NamedSpinLock internally to protect the data.
pub fn LockPayload(comptime T: type) type {
    return struct {
        const Self = @This();

        lock: NamedSpinLock,
        data: T,

        pub fn init(name: []const u8, data: T) Self {
            return Self{
                .lock = NamedSpinLock.init(name),
                .data = data,
            };
        }

        // returns a Guard object giving temporary exclusive access to the data
        pub fn acquire(self: *Self) Guard {
            const prev = self.lock.lock();
            return Guard{ .payload = self, .prev_mstatus = prev };
        }

        // unlike other languages / environments, we must explicitly get the
        // contents of the guard (the data we want to use) and release it
        // when we're done using it exclusively.
        pub const Guard = struct {
            payload: *Self,
            prev_mstatus: usize,

            pub fn get(self: Guard) *T {
                return &self.payload.data;
            }

            pub fn release(self: Guard) void {
                self.payload.lock.unlock(self.prev_mstatus);
            }
        };
    };
}
