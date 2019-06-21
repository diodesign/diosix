# diosix RV32G/RV64G kernel low-level per-CPU core timer control
#
# (c) Chris Williams, 2019.
#
# See LICENSE for usage and copying.

.altmacro

.section .text
.align 4

.global platform_timer_target
.global platform_timer_now
.global platform_timer_irq_enable

# kernel constants, such as stack and lock locations
.include "src/platform/riscv/asm/consts.s"

# special memory mapped registers for controlling per-CPU timers 
# when the value at mtimecmp > mtime then an IRQ is raised
# this is used to drive the scheduling system  
# mtime is in a single location. each core has its own mtimecmp
# at mtimecmp + hartid * 8
.equ CLINT_BASE,  0x2000000
.equ mtimecmp,    CLINT_BASE + 0x4000
.equ mtime,       CLINT_BASE + 0xbff8

# set the per-CPU timer trigger value. when the timer value >= target, IRQ is raised
# trigger values are stored one 64-bit word per CPU core starting from mtimecmp
# => on RV32: (a0, a1) = trigger on this 64-bit timer value 
#    on RV64: a0 = trigger on this 64-bit timer value 
platform_timer_target:
  li      t1, mtimecmp      # get base address of time compare register bank
  csrrc   t2, mhartid, x0
  slli    t2, t2, 3         # t2 = hartid * 8 bytes (hartid * one 64-bit word)
  add     t1, t1, t2        # t1 = mtimecmp + hartid * 8 = address of this CPU's mtimecmp
.if ptrwidth == 32
  li      t0, -1            # for RV32, manuals recommend setting all high bits first
  sw      t0, 4(t1)
  sw      a0, 0(t1)         # then write low 32-bit word
  sw      a1, 4(t1)         # then the high 32-bit word
.else
  sd      a0, 0(t1)         # 64-bit CPUs can just do a single write
.endif
  ret

# return the CPU timer's latest value
# <= on RV32: a0, a1 = 64-bit value of timer register
#    on RV64: a0 = 64-bit value of timer register
platform_timer_now:
  li  t0, mtime
.if ptrwidth == 32
  lw  a1, 4(t0)       # 32-bit CPUs have to read hi then lo
  lw  a0, 0(t0)
.else
  ld  a0, 0(t0)       # 64-bit CPUs can just read a whole double word
.endif
  ret

# enable the per-CPU incremental timer
platform_timer_irq_enable:
  li      t0, 1 << 7    # bit 7 = machine timer enable
  csrrs   x0, mie, t0
  ret
