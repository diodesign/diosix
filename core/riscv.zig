// RISC-V non-hardware-specific routines
//
// Copyright (c) 2024 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const alloc = @import("alloc.zig");

extern fn hw_private_variables() *CPUContext;
extern fn hw_heap_base() usize;
extern fn hw_heap_size() usize;

// each thread context is the contents of its 32 general purpose CPU registers
pub const ThreadContext = [32]usize;

// the per-CPU context for the physical core running this thread
const CPUContext = struct {
    cpu_core_id: usize,
    allocator: alloc.Allocator,
};

// return a pointer to the CPU context for the core running this thread
pub inline fn get_cpu_context() *CPUContext {
    return hw_private_variables();
}

// return the base address of the heap for the core running this thread
pub inline fn get_cpu_heap_base() usize {
    return hw_heap_base();
}

// return the size of the heap for the core running this thread
pub inline fn get_cpu_heap_size() usize {
    return hw_heap_size();
}

// return the mcause CSR
pub inline fn read_mcause() usize {
    return asm volatile ("csrr %[ret], mcause"
        : [ret] "=r" (-> usize),
    );
}

// return the mepc CSR
pub inline fn read_mepc() usize {
    return asm volatile ("csrr %[ret], mepc"
        : [ret] "=r" (-> usize),
    );
}

// return the mtval CSR
pub inline fn read_mtval() usize {
    return asm volatile ("csrr %[ret], mtval"
        : [ret] "=r" (-> usize),
    );
}
