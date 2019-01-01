# kernel low-level per-CPU core timer control
#
#
# (c) Chris Williams, 2018.
# See LICENSE for usage and copying.

.altmacro

.section .text
.align 4

.global platform_timer_target
.global platform_timer_now
.global platform_timer_irq_enable

# include kernel constants, such as stack and lock locations
.include "src/platform/riscv32/common/asm/consts.s"

# special memory mapped registers for controlling per-CPU timers 
# when the value at mtimecmp > mtime then an IRQ is raised
# this is used to drive the scheduling system  
# mtime is in a single location. each core has its own mtimecmp
# at mtimecmp + hartid * 8
.equ CLINT_BASE,  0x2000000
.equ mtimecmp,    CLINT_BASE + 0x4000
.equ mtime,       CLINT_BASE + 0xbff8

# set the per-CPU timer trigger value. when the timer value >= target, IRQ is raised
# => (a0, a1) = trigger on this 64-bit timer value 
platform_timer_target:
  # safely update the 64-bit timer target register with 32-bit writes
  li      t0, -1
  li      t1, mtimecmp
  csrrc   t2, mhartid, x0
  slli    t2, t2, 3         # t2 = hartid * 8
  add     t1, t1, t2        # t1 = mtimecmp + hartid * 8
  sw      t0, 0(t1)
  sw      a1, 4(t1)
  sw      a0, 0(t1)
  ret

# return the CPU timer's latest value
# <= a0, a1 = 64-bit value of timer register
platform_timer_now:
  li  t0, mtime
  lw  a1, 4(t0)
  lw  a0, 0(t0)
  ret

# enablet he per-CPU incremental timer
platform_timer_irq_enable:
  li      t0, 1 << 7    # bit 7 = machine timer enable
  csrrs   x0, mie, t0
  ret
