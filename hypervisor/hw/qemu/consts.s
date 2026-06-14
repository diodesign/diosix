# hypervisor memory locations and layout for Qemu-compatible RV64 targets
#
# Copyright (c) 2024 Chris Williams <chrisw@diosix.org>
# SPDX-License-Identifier: MIT

.equ PAGE_SIZE, (4096)

# during exceptions and interrupts (xint), reserve space for 32 CPU registers, eight-bytes wide each
.equ  XINT_REGISTER_FRAME_SIZE,   (32 * 8)

# the hypervisor is laid out as follows in physical memory on bootup, ascending:
# (all addresses should be 4KB word aligned, and defined in the linker script)
#   __hypervisor_start = base of hypervisor
#   .
#   . hypervisor text, read-only data, read-write data / bss
#   .
#   __hypervisor_end = top of the hypervisor's static footprint
#   .
#   . per-CPU slabs of physical memory: each CPU core has in order...
#   .   exeception / interrupt stack
#   .   page of private variables
#   .   private heap space

# describe per-CPU slab, all sizes in bytes
.equ CPU_SLAB_SHIFT,         (24) # total size of per-CPU slab = 1 << CPU_SLAB_SHIFT = 16MB
.equ CPU_SLAB_SIZE,          (1 << CPU_SLAB_SHIFT)
.equ CPU_STACK_BASE,         (0)
.equ CPU_STACK_SIZE,         (32 * 1024)
.equ CPU_PRIVATE_VARS_BASE,  (CPU_STACK_BASE + CPU_STACK_SIZE)
.equ CPU_PRIVATE_VARS_SIZE,  (PAGE_SIZE)
.equ CPU_HEAP_BASE,          (CPU_PRIVATE_VARS_BASE + CPU_PRIVATE_VARS_SIZE)
.equ CPU_HEAP_AREA_SIZE,     (CPU_SLAB_SIZE - CPU_HEAP_BASE)
