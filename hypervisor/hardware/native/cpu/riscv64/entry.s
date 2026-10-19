# Prepare QEMU-virt-compatible RV64 system environment for the hypervisor.
#
# Copyright (c) 2024, 2026 Chris Williams <chrisw@diosix.org>
# SPDX-License-Identifier: MIT

.include "hypervisor/hardware/native/cpu/riscv64/consts.s"

# Physical memory map of a QEMU virt system:
# [ https://github.com/qemu/qemu/blob/master/hw/riscv/virt.c ]
#
# 0x00000000, size: 0x100:     Debug ROM/data
# 0x00001000, size: 0x11000:   Boot ROM
# 0x00100000, size: 0x1000:    Hardware test area
# 0x02000000, size: 0x10000:   CLINT (Core Local Interruptor)
# 0x10000000, size: 0x100:     UART interface
# 0x10001000, size: 0x1000:    VirtIO peripherals
# 0x0c000000, size: 0x4000000: PLIC (Platform-Level Interrupt Controller)
# 0x80000000: DRAM base <-- hypervisor loaded and entered here (_start)

.section .text.entry
.align 8

.global _start

# QEMU's boot ROM provides a bare-bones environment with each core starting
# here. Note: exceptions and interrupts (xint) are disabled.
# => a0 = per-system unique CPU core ID, aka hart ID
#    a1 = pointer to device tree describing the environment
_start:
    # Atomically claim a sequential internal CPU ID starting at 0 (0, 1, 2...).
    # CPU ID 0 is the boot CPU; IDs 0..31 use contiguous static slabs;
    # IDs 32+ use dynamically allocated slabs.
    la          t0, boot_lottery_cpu_id
    li          t1, 1
    amoadd.w.aq t3, t1, (t0)
    mv          a0, t3          # a0 = lottery-assigned sequential CPU ID

    # Only CPU 0 (the lottery winner) runs early boot preparation first.
    # Secondary cores wait until CPU 0 finishes initializing the system.
    beqz        t3, boot_cpu_prep

    la          t0, boot_prep_done
secondary_wait_loop:
    amoor.w.aq  t1, x0, (t0)
    beqz        t1, secondary_wait_loop
    li          a1, 0           # Secondary cores do not pass DTB
    j           setup_cpu_slab

boot_cpu_prep:
    # --------------------------------------------------------------------
    # Zero the BSS (safe because boot_lottery_cpu_id and boot_prep_done are in
    # .data, and all secondary cores are waiting in secondary_wait_loop).
    # --------------------------------------------------------------------
    la        t1, __bss_start
    la        t2, __bss_end
    bgeu      t1, t2, clear_bss_done
clear_bss_loop:
    sd        x0, (t1)
    addi      t1, t1, 8
    bltu      t1, t2, clear_bss_loop

clear_bss_done:
    # -------------------------------------------------------------
    # Move DTB out of the way only if it overlaps Boot CPU 0's slab
    # (__hypervisor_end .. __hypervisor_end + CPU_SLAB_SIZE).
    # Secondary slabs (1..N) are untouched until CPU 0 parses the DTB
    # into its internal DeviceTree heap structure and sets boot_prep_done.
    # -------------------------------------------------------------
    beqz      a1, setup_cpu_slab
    la        t1, __hypervisor_end
    li        t2, CPU_SLAB_SIZE
    add       t1, t1, t2        # t1 = end of CPU 0's slab

    bgeu      a1, t1, setup_cpu_slab

    # Validate DTB magic (0xd00dfeed big-endian) byte-by-byte.
    lbu       t0, (DTB_MAGIC_OFFSET + 0)(a1)
    li        t2, DTB_MAGIC_BYTE0
    bne       t0, t2, setup_cpu_slab
    lbu       t0, (DTB_MAGIC_OFFSET + 1)(a1)
    li        t2, DTB_MAGIC_BYTE1
    bne       t0, t2, setup_cpu_slab
    lbu       t0, (DTB_MAGIC_OFFSET + 2)(a1)
    li        t2, DTB_MAGIC_BYTE2
    bne       t0, t2, setup_cpu_slab
    lbu       t0, (DTB_MAGIC_OFFSET + 3)(a1)
    li        t2, DTB_MAGIC_BYTE3
    bne       t0, t2, setup_cpu_slab

    # Extract big-endian totalsize from DTB offset 4.
    lbu       t0, DTB_HEADER_TOTALSIZE_OFFSET(a1)
    lbu       t2, (DTB_HEADER_TOTALSIZE_OFFSET + 1)(a1)
    lbu       t4, (DTB_HEADER_TOTALSIZE_OFFSET + 2)(a1)
    lbu       t5, (DTB_HEADER_TOTALSIZE_OFFSET + 3)(a1)
    slli      t0, t0, 24
    slli      t2, t2, 16
    slli      t4, t4, 8
    or        t0, t0, t2
    or        t0, t0, t4
    or        t0, t0, t5        # t0 = totalsize in bytes

    beqz      t0, setup_cpu_slab
    li        t2, MAX_DTB_SIZE
    bgtu      t0, t2, setup_cpu_slab

    # Align size to 8 bytes and copy backwards (overlap-safe since a1 < t1).
    addi      t0, t0, 7
    andi      t0, t0, STACK_ALIGN_MASK
    add       t2, a1, t0
    add       t4, t1, t0
copy_dtb_loop:
    addi      t2, t2, -8
    addi      t4, t4, -8
    ld        t5, 0(t2)
    sd        t5, 0(t4)
    addi      t0, t0, -8
    bgtz      t0, copy_dtb_loop

    mv        a1, t1            # a1 = relocated DTB address above CPU 0 slab

setup_cpu_slab:
    # Cores 0..31 (t3 < MAX_PHYS_CORES) use fixed contiguous slabs starting at
    # __hypervisor_end. Cores 32+ acquire the dynamic bootstrap stack to
    # allocate their slab in main().
    li        t0, MAX_PHYS_CORES
    bgeu      t3, t0, setup_dynamic_bootstrap

    # slab address = __hypervisor_end + (cpu_core_id << CPU_SLAB_SHIFT)
    la        t1, __hypervisor_end
    slli      t2, t3, CPU_SLAB_SHIFT
    add       t3, t1, t2

    # Set mscratch to top of this CPU's exception/interrupt stack.
    li        t2, CPU_STACK_SIZE
    add       t4, t2, t3
    csrw      mscratch, t4

    # Set tp to this CPU's private variables (CpuContext).
    li        t1, CPU_PRIVATE_VARS_BASE
    add       t1, t1, t3
    mv        tp, t1

    # Set boot sp halfway down the xint stack.
    srli      t1, t2, 1
    sub       sp, t4, t1
    j         call_main

setup_dynamic_bootstrap:
    # Serialize cores 32+ on a small bootstrap stack while they allocate their
    # dynamic slab in main().
    la          t0, dyn_boot_lock
    li          t1, 1
dyn_lock_loop:
    amoswap.w.aq t2, t1, (t0)
    bnez        t2, dyn_lock_loop
    la          sp, dyn_boot_stack_top

call_main:
    # Call main(cpu_core_id, fdt_paddr).
    la        t0, main
    jalr      ra, t0, 0

    csrw      mie, x0
infinite_loop:
    wfi
    j         infinite_loop


# Variables in .data (not zeroed by clear_bss_loop).
.section .data
.align 8
boot_lottery_cpu_id:
    .word 0
.global boot_prep_done
boot_prep_done:
    .word 0
.global dyn_boot_lock
dyn_boot_lock:
    .word 0

.section .bss
.align 16
dyn_boot_stack:
    .space INITIAL_FDT_PAD_BYTES
dyn_boot_stack_top: