# Generic utility functions for Qemu-compatible hardware
#
# Copyright (c) 2024 Chris Williams <chrisw@diosix.org>
# SPDX-License-Identifier: MIT

.section .text
.align 8

.global hw_putchar
.global hw_private_variables
.global hw_heap_base
.global hw_heap_size
.global hw_pause
.global hw_reboot
.global hw_shutdown

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
  nop
  ret