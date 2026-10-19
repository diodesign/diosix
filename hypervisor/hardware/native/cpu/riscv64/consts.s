# Hypervisor memory locations and layout for QEMU-compatible RV64 targets.
#
# Copyright (c) 2024, 2026 Chris Williams <chrisw@diosix.org>
# SPDX-License-Identifier: MIT

.equ PAGE_SIZE, (4096)

# Maximum number of physical cores with static bootstrap memory slabs.
# Keep in sync with STATIC_PHYS_CORES in cpu/riscv64/mod.zig.
.equ MAX_PHYS_CORES, 32

# During exceptions and interrupts (xint), reserve space for 32 CPU registers,
# eight bytes wide each.
.equ XINT_REGISTER_FRAME_SIZE, (32 * 8)

# The hypervisor is laid out as follows in physical memory on bootup, ascending:
# (all addresses are 4 KiB page-aligned, defined in the linker script)
#   __hypervisor_start = base of hypervisor
#   .
#   . hypervisor text, read-only data, read-write data / bss
#   .
#   __hypervisor_end = top of the hypervisor's static footprint
#   .
#   . per-CPU slabs of physical memory: each CPU core has in order...
#   .   exception / interrupt stack
#   .   page of private variables
#   .   private heap space

# Describe per-CPU slab, all sizes in bytes (1 << 22 = 4 MiB).
.equ CPU_SLAB_SHIFT,         (22)
.equ CPU_SLAB_SIZE,          (1 << CPU_SLAB_SHIFT)
.equ CPU_STACK_BASE,         (0)
.equ CPU_STACK_SIZE,         (512 * 1024)
.equ CPU_PRIVATE_VARS_BASE,  (CPU_STACK_BASE + CPU_STACK_SIZE)
.equ CPU_PRIVATE_VARS_SIZE,  (PAGE_SIZE)
.equ CPU_HEAP_BASE,          (CPU_PRIVATE_VARS_BASE + CPU_PRIVATE_VARS_SIZE)
.equ CPU_HEAP_AREA_SIZE,     (CPU_SLAB_SIZE - CPU_HEAP_BASE)

# CSR numbers.
.equ CSR_HENVCFG,            0x60a
.equ CSR_VSTIMECMP,          0x24d
.equ CSR_STIMECMP,           0x14d
.equ CSR_SENVCFG,            0x10a

# GuestState struct offsets.
.equ GS_VSENVCFG_OFFSET,     72

# mstatus bits.
.equ MSTATUS_VS_DIRTY,       (3 << 9)   # Vector extension dirty state
.equ MSTATUS_FS_DIRTY,       (3 << 13)  # Floating-point extension dirty state
.equ MSTATUS_TW,             (1 << 21)  # Timeout Wait (trap WFI in VS-mode)

# henvcfg bits.
.equ HENVCFG_CBO_MASK,       0xf0       # CBZE, CBCFE, CBIE (bits 4..7)
.equ HENVCFG_STCE_BIT,       63         # STCE enable bit

# PMP entry constants.
.equ PMP_R,                  (1 << 0)
.equ PMP_W,                  (1 << 1)
.equ PMP_X,                  (1 << 2)
.equ PMP_A_NAPOT,            (3 << 3)
.equ PMP_RWX_NAPOT,          (PMP_R | PMP_W | PMP_X | PMP_A_NAPOT)

# mideleg: Delegate virtual supervisor interrupts (VSSIP=2, VSTIP=6, VSEIP=10).
.equ MIDELEG_VSSIP,          (1 << 2)
.equ MIDELEG_VSTIP,          (1 << 6)
.equ MIDELEG_VSEIP,          (1 << 10)
.equ MIDELEG_DELEGATED,      (MIDELEG_VSSIP | MIDELEG_VSTIP | MIDELEG_VSEIP)

# medeleg: Delegate guest exceptions (excluding illegal instruction 2,
# supervisor ecall 9, and machine ecall 11).
.equ MEDELEG_DELEGATED,      0xb1fb

# Device tree header and early boot constants.
.equ DTB_MAGIC_OFFSET,            0
.equ DTB_HEADER_TOTALSIZE_OFFSET, 4
.equ DTB_MAGIC_BYTE0,             0xd0
.equ DTB_MAGIC_BYTE1,             0x0d
.equ DTB_MAGIC_BYTE2,             0xfe
.equ DTB_MAGIC_BYTE3,             0xed
.equ MAX_DTB_SIZE,                (2 * 1024 * 1024)
.equ STACK_ALIGN_MASK,            -8
.equ INITIAL_FDT_PAD_BYTES,       16384
