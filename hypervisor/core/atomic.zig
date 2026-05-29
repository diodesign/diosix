// generic atomic routines for spinlocks and so on
//
// Copyright (c) 2024-2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const value = std.atomic.Value;
const ordering = std.builtin.AtomicOrder;

// primitives for atomically reading and writing boolean flags
pub fn writeBool(ptr: *bool, val: bool) void {
    @atomicStore(bool, ptr, val, ordering.seq_cst);
}

pub fn readBool(ptr: *bool) bool {
    return @atomicLoad(bool, ptr, ordering.seq_cst);
}

// basic blocking spinlock implementation
const SpinLock = struct {
    lock_value: value(bool),

    pub fn init() SpinLock {
        return SpinLock{ .lock_value = value(bool).init(false) };
    }

    // call lock() to acquire the lock, waiting endlessly until it's available
    pub fn lock(self: *SpinLock) void {
        while (self.lock_value.swap(true, ordering.acq_rel) != false) {
            // spin until we get the lock. avoid hw_pause (wfi) during early boot
            // to prevent cores from waiting for interrupts that aren't set up yet.
            std.atomic.spinLoopHint();
        }
    }

    // release the lock with unlock() so others can acquire it
    pub fn unlock(self: *SpinLock) void {
        self.lock_value.store(false, ordering.release);
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
    pub fn lock(self: *NamedSpinLock) void {
        self.spinlock.lock();
    }

    // release this spinlock so others can acquire it
    pub fn unlock(self: *NamedSpinLock) void {
        self.spinlock.unlock();
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
            self.lock.lock();
            return Guard{ .payload = self };
        }

        // unlike other languages / environments, we must explicitly get the
        // contents of the guard (the data we want to use) and release it
        // when we're done using it exclusively.
        pub const Guard = struct {
            payload: *Self,

            pub fn get(self: Guard) *T {
                return &self.payload.data;
            }

            pub fn release(self: Guard) void {
                self.payload.lock.unlock();
            }
        };
    };
}
