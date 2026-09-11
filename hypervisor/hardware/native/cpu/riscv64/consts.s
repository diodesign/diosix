# hypervisor memory locations and layout for Qemu-compatible RV64 targets
#
# Copyright (c) 2024 Chris Williams <chrisw@diosix.org>
# SPDX-License-Identifier: MIT

.equ PAGE_SIZE, (4096)

# maximum number of physical cores supported
# keep this in sync with MAX_PHYS_CORES in hypervisor/hardware/native/cpu/riscv64/mod.zig
# we'll do this automatically when we later increase this core count
.equ MAX_PHYS_CORES, 16

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
.equ CPU_SLAB_SHIFT,         (22) # total size of per-CPU slab = 1 << CPU_SLAB_SHIFT = 4MB
.equ CPU_SLAB_SIZE,          (1 << CPU_SLAB_SHIFT)
.equ CPU_STACK_BASE,         (0)
.equ CPU_STACK_SIZE,         (512 * 1024)
.equ CPU_PRIVATE_VARS_BASE,  (CPU_STACK_BASE + CPU_STACK_SIZE)
.equ CPU_PRIVATE_VARS_SIZE,  (PAGE_SIZE)
.equ CPU_HEAP_BASE,          (CPU_PRIVATE_VARS_BASE + CPU_PRIVATE_VARS_SIZE)
.equ CPU_HEAP_AREA_SIZE,     (CPU_SLAB_SIZE - CPU_HEAP_BASE)

# CSR Numbers
.equ CSR_HENVCFG,            0x60a
.equ CSR_VSTIMECMP,          0x24d
.equ CSR_STIMECMP,           0x14d

# mstatus bits
.equ MSTATUS_VS_DIRTY,       (3 << 9)   # Vector extension dirty state
.equ MSTATUS_FS_DIRTY,       (3 << 13)  # Floating-point extension dirty state
.equ MSTATUS_TW,             (1 << 21)  # Timeout Wait (trap WFI in VS-mode)

# henvcfg bits
.equ HENVCFG_CBO_MASK,       0xf0       # CBZE, CBCFE, CBIE (bits 4..7)
.equ HENVCFG_STCE_BIT,       63         # STCE enable bit

# PMP entry constants
.equ PMP_R,                  (1 << 0)
.equ PMP_W,                  (1 << 1)
.equ PMP_X,                  (1 << 2)
.equ PMP_A_NAPOT,            (3 << 3)
.equ PMP_RWX_NAPOT,          (PMP_R | PMP_W | PMP_X | PMP_A_NAPOT) # 0x1f

# mideleg: Delegate virtual supervisor interrupts (VSSIP=2, VSTIP=6, VSEIP=10)
.equ MIDELEG_VSSIP,          (1 << 2)
.equ MIDELEG_VSTIP,          (1 << 6)
.equ MIDELEG_VSEIP,          (1 << 10)
.equ MIDELEG_DELEGATED,      (MIDELEG_VSSIP | MIDELEG_VSTIP | MIDELEG_VSEIP) # 0x0444

# medeleg: Delegate guest exceptions (excluding illegal instruction 2, supervisor ecall 9, machine ecall 11)
.equ MEDELEG_DELEGATED,      0xb1fb

# Device tree header
.equ DTB_HEADER_TOTALSIZE_OFFSET, 4
