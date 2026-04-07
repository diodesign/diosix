// RISC-V non-hardware-specific routines
//
// Copyright (c) 2024, 2025, 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const alloc = @import("alloc.zig");

extern fn hw_private_variables() *CpuContext;
extern fn hw_heap_base() usize;
extern fn hw_heap_size() usize;

// each thread context is the contents of its 32 general purpose CPU registers
pub const ThreadContext = [32]usize;

// the per-CPU context for the physical core running this thread
const CpuContext = struct {
    cpu_core_id: usize,
    allocator: alloc.HeapAllocator,
};

// return a pointer to the CPU context for the core running this thread
pub inline fn getCPUContext() *CpuContext {
    return hw_private_variables();
}

// return the base address of the heap for the core running this thread
pub inline fn getCPUHeapBase() usize {
    return hw_heap_base();
}

// return the size of the heap for the core running this thread
pub inline fn getCPUHeapSize() usize {
    return hw_heap_size();
}

// initialize the heap allocator for the CPU core running this thread
pub fn initCPUHeapAllocator() !void {
    const cpu_context = getCPUContext();
    try cpu_context.allocator.init(getCPUHeapBase(), getCPUHeapSize());
}

// return a standard Zig allocator for the CPU core running this thread
pub fn getCPUHeapAllocator() alloc.Allocator {
    const cpu_context = getCPUContext();
    return cpu_context.allocator.allocator();
}

// return the mcause CSR
pub inline fn readMcause() usize {
    return asm volatile ("csrr %[ret], mcause"
        : [ret] "=r" (-> usize),
    );
}

// return the mepc CSR
pub inline fn readMepc() usize {
    return asm volatile ("csrr %[ret], mepc"
        : [ret] "=r" (-> usize),
    );
}

// return the mtval CSR
pub inline fn readMtval() usize {
    return asm volatile ("csrr %[ret], mtval"
        : [ret] "=r" (-> usize),
    );
}
