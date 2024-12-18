# Prepare Qemu-virt-compatible RV64 system environment for running the hypervisor proper
#
# Copyright (c) 2024 Chris Williams <chrisw@diosix.org>
# SPDX-License-Identifier: MIT

.include "hw/qemu/consts.s"

# physical memory map of a Qemu virt system
# [ https://github.com/qemu/qemu/blob/master/hw/riscv/virt.c ]
#
# 0x00000000, size: 0x100:     Debug ROM/data
# 0x00001000, size: 0x11000:   Boot ROM
# 0x00100000, size: 0x1000:    Hardware test area
# 0x02000000, size: 0x10000:   CLINT (Core Local Interruptor)
# 0x10000000, size: 0x100:     UART interface
# 0x10001000, size: 0x1000:    VirtIO peripherals 
# 0x0c000000, size: 0x4000000: PLIC (Platform Level Interrupt Controller)
# 0x80000000: DRAM base <-- hypervisor + entered loaded here, _start must be placed here

.section .text.entry
.align 8

.global _start

# Qemu's boot ROM provides us a bare-bones environment, with each core starting here
# note: exceptions and interrupts are disabled
# => a0 = per-system unique CPU core ID, aka hart ID
#    a1 = pointer to device tree describing the environment
_start:
    # each core should grab a slab of memory starting from the end of the hypervisor.
    # in order to scale to many cores, not waste too much memory, and to cope with non-linear
    # CPU ID / hart ID, each core will take memory using an atomic counter.
    # thus, memory is allocated on a first come, first served basis.
    la        t1, cpu_core_id_counter
    li        t2, 1
    amoadd.w  t3, t2, (t1)
    mv        a0, t3
    # now a0 = runtime-assigned linear CPU core ID, counting from 0

    # use t3 this as a multiplier from the end of the hypervisor, using shifts to keep things easy
    la        t1, __hypervisor_end
    slli      t3, t3, HV_CPU_SLAB_SHIFT
    add       t3, t3, t1
    # t3 = base of this CPU's private memory slab

    # write the top of the exception and interrupt (xint) stack to mscratch.
    # this allows us to find the stack after an xint fires
    li        t1, HV_CPU_STACK_BASE
    li        t2, HV_CPU_STACK_SIZE
    add       t4, t2, t1
    add       t4, t4, t3
    # t4 = top of the stack, t2 = stack size, t1 = stack base from slab base
    csrrw     x0, mscratch, t4

    # use the lower half of the xint stack to bring up the hypervisor.
    # set the boot stack pointer to halfway down that stack.
    # when we're ready to start running guests, the whole stack is flattened anyway
    # and ready for full use by xint handlers.
    srli      t1, t2, 1
    sub       sp, t4, t1

    # set up early xint handling (corrupts t0) and enable xint
    call      xint

    # boot CPU core (ID 0) needs to zero the BSS
    la        t0, bss_cleared
    beq       x0, a0, clear_bss
    # t0 => flag to signal bss fully cleared

    # other CPU cores need to wait for clear_bss_finished
    # to change from zero to non-zero to indicate the BSS is clear
clear_bss_wait_loop:
    amoswap.w t1, x0, (t0)
    beq       x0, t1, clear_bss_wait_loop
    j         clear_bss_loop_end

clear_bss:
    la        t1, __bss_start
    la        t2, __bss_end
    bgeu      t1, t2, clear_bss_loop_end # avoid empty or malformed bss 
clear_bss_loop:
    sd        x0, (t1)
    addi      t1, t1, 8
    bltu      t1, t2, clear_bss_loop

clear_bss_loop_end:
    li        t1, 1        # set clear_bss_finished to 1 now we're done
    amoswap.w x0, t1, (t0) # t0 => bss_cleared

    # call main with:
    # a0 = runtime-assigned CPU ID number
    # a1 = pointer to start of devicetree
    # a2 = big-endian length of the devicetree (ugh)
    lw        a2, 4(a1)       # 32-bit size of tree stored from byte 4 in tree blob
    la        t0, main
    jalr      ra, t0, 0

    # fall through to an infinite loop
infinite_loop:
    j         infinite_loop


# variables
.align 8
cpu_core_id_counter:
    .word 0

.align 8
bss_cleared:
    .word 0