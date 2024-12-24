// generic atomic routines for spinlocks and so on
//
// Copyright (c) 2024 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const value = std.atomic.Value;
const ordering = std.builtin.AtomicOrder;

extern fn hw_pause() void;

// primitives for atomically setting and unlocking boolean flags
pub fn set_bool(ptr: *bool, val: bool) void {
    @atomicStore(bool, ptr, val, ordering.seq_cst);
}

pub fn read_bool(ptr: *bool) bool {
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
        while (self.lock_value.swap(true, ordering.acquire) != false) {
            // spin until we get the lock
            hw_pause();
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
