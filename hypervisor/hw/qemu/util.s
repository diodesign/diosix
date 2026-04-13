# Generic utility functions for Qemu-compatible hardware
#
# Copyright (c) 2024 Chris Williams <chrisw@diosix.org>
# SPDX-License-Identifier: MIT

.section .text
.align 8

.global hw_putchar
.global hw_getchar
.global hw_set_timer
.global hw_run_vcore
.global hw_private_variables
.global hw_heap_base
.global hw_heap_size
.global hw_pause
.global hw_reboot
.global hw_shutdown
.global hw_pmp_init

# hypervisor constants, such as stack and lock locations
.include "hypervisor/hw/qemu/consts.s"

# reboot the host machine
hw_reboot:
  li t0, 0x100000 # SiFive Test device base address
  li t1, 0x7777   # FINISHER_RESET
  sw t1, 0(t0)
  ret

# shutdown the host machine
hw_shutdown:
  li t0, 0x100000 # SiFive Test device base address
  li t1, 0x5555   # FINISHER_PASS
  sw t1, 0(t0)
  ret

# print a character to the Qemu serial console
# a0 = character to print
hw_putchar:
  li t0, 0x10000000 # UART0 base address
  sb a0, 0(t0)
  ret

# read a character from the Qemu serial console
# <= a0 = character read, or -1 if none waiting
hw_getchar:
  li t0, 0x10000000 # UART0 base address
  lb t1, 5(t0)      # read line status register
  andi t1, t1, 0x01 # check for data ready bit
  beqz t1, hw_getchar_none
  lb a0, 0(t0)      # read character from receive buffer register
  ret
hw_getchar_none:
  li a0, -1
  ret

# set the machine-level timer to fire at the given time
# a0 = time to fire at
hw_set_timer:
  # CLINT base 0x02000000. mtimecmp starts at 0x4000
  li t0, 0x02004000
  csrr t1, mhartid
  slli t1, t1, 3   # hart id * 8
  add t0, t0, t1
  sd a0, 0(t0)      # write 64-bit time to mtimecmp
  ret

# load all registers from the given context and mret to the guest
# a0 = pointer to ThreadContext [32]usize
# a1 = pointer to MachineState
# a2 = pointer to GuestState
hw_run_vcore:
  ld t0, 0(a1)      # mepc
  csrw mepc, t0
  ld t0, 8(a1)      # mstatus
  csrw mstatus, t0

  # set H-extension CSRs if H-paging is enabled (hgatp != 0)
  ld t1, 24(a1)     # hgatp
  beqz t1, hw_run_vcore_no_h
  ld t0, 16(a1)     # hstatus
  csrw hstatus, t0
  csrw hgatp, t1
  ld t0, 32(a1)     # hvip
  csrw hvip, t0
  ld t0, 40(a1)     # hedeleg
  csrw hedeleg, t0
  ld t0, 48(a1)     # hideleg
  csrw hideleg, t0
  
  # set VS-mode CSRs from a2
  ld t0, 0(a2)      # vsstatus
  csrw vsstatus, t0
  ld t0, 8(a2)      # vsie
  csrw vsie, t0
  ld t0, 16(a2)     # vstvec
  csrw vstvec, t0
  ld t0, 24(a2)     # vsscratch
  csrw vsscratch, t0
  ld t0, 32(a2)     # vsepc
  csrw vsepc, t0
  ld t0, 40(a2)     # vscause
  csrw vscause, t0
  ld t0, 48(a2)     # vstval
  csrw vstval, t0
  ld t0, 56(a2)     # vsatp
  csrw vsatp, t0

  # Flush any stale G-stage TLB entries
  hfence.gvma

hw_run_vcore_no_h:
  # use a0 as temporary base pointer for GPR restoration
  # load all registers, skipping zero (x0) and sp (x2)
  ld x1, 8(a0)
  # restore gp (x3), tp (x4)
  ld x3, 24(a0)
  ld x4, 32(a0)
  # x5 (t0) - handled later
  # x6 (t1) - handled later
  # x7 (t2) to x9 (s1)
  ld x7, 56(a0)
  ld x8, 64(a0)
  ld x9, 72(a0)
  # restore a1 (x11) to a7 (x17)
  ld x11, 88(a0)
  ld x12, 96(a0)
  ld x13, 104(a0)
  ld x14, 112(a0)
  ld x15, 120(a0)
  ld x16, 128(a0)
  ld x17, 136(a0)
  # restore s2 (x18) to s11 (x27)
  ld x18, 144(a0)
  ld x19, 152(a0)
  ld x20, 160(a0)
  ld x21, 168(a0)
  ld x22, 176(a0)
  ld x23, 184(a0)
  ld x24, 192(a0)
  ld x25, 200(a0)
  ld x26, 208(a0)
  ld x27, 216(a0)
  # restore t3 (x28) to t6 (x31)
  ld x28, 224(a0)
  ld x29, 232(a0)
  ld x30, 240(a0)
  ld x31, 248(a0)

  # restore remaining temporaries and sp
  ld x5, 40(a0)   # t0
  ld x6, 48(a0)   # t1
  ld x2, 16(a0)   # sp
  
  # finally restore a0 (x10) last
  ld x10, 80(a0)
  
  mret

# return pointer to this CPU core's private variables
# <= a0 = pointer to CPU core private variables
hw_private_variables:
  # get base of private variables from top of IRQ stack, held in mscratch
  csrrs a0, mscratch, x0
  ret

# return base address of this CPU core's heap - right above private vars 
# <= a0 = pointer to heap base (corrupts t0)
hw_heap_base:
  csrrs a0, mscratch, x0  # private vars start above CPU xint stack
  li    t0, CPU_PRIVATE_VARS_SIZE
  add   a0, a0, t0
  ret

# return total empty size of this CPU core's heap area
# <= a0 = heap size in bytes
hw_heap_size:
  li  a0, CPU_HEAP_AREA_SIZE
  ret

# signal to the CPU core that we're waiting on a condition to clear
hw_pause:
  wfi
  ret

# Initialize Physical Memory Protection (PMP)
# Set a permissive window for all memory for lower privilege modes.
# Isolated guests are then handled by the H-extension's HGATP (G-stage) paging.
hw_pmp_init:
  # Entry 0: covers entire 64-bit address space
  li t0, -1
  csrw pmpaddr0, t0
  # pmpcfg0: Entry 0 is NAPOT with R, W, and X bits set (0x1f)
  # NAPOT mode = 11 (bit 3-4), R=1, W=1, X=1 (bits 0-2)
  li t0, 0x1f
  csrw pmpcfg0, t0
  ret