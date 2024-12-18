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
#   . per-CPU slabs of physical memory: each CPU core has...
#   .   exeception / interrupt stack
#   .   page of private variables
#   .   private heap space

# describe per-CPU slab, all sizes in bytes
.equ HV_CPU_SLAB_SHIFT,         (20) # total size of per-CPU slab = 1 << HV_CPU_SLAB_SHIFT = 1MB
.equ HV_CPU_SLAB_SIZE,          (1 << HV_CPU_SLAB_SHIFT)
.equ HV_CPU_STACK_BASE,         (0)
.equ HV_CPU_STACK_SIZE,         (128 * 1024)
.equ HV_CPU_PRIVATE_VARS_BASE,  (HV_CPU_STACK_BASE + HV_CPU_STACK_SIZE)
.equ HV_CPU_PRIVATE_VARS_SIZE,  (PAGE_SIZE)
.equ HV_CPU_HEAP_BASE,          (HV_CPU_PRIVATE_VARS_BASE + HV_CPU_PRIVATE_VARS_SIZE)
.equ HV_CPU_HEAP_AREA_SIZE,     (HV_CPU_SLAB_SIZE - HV_CPU_HEAP_BASE)
