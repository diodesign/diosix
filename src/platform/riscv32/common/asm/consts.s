# kernel top page variables for RV32G targets
#
# Top page is a 4KB (4096 byte) page of read-write DRAM
# It's the final 4KB page in the first 16MB of physical RAM,
# and placed right above the boot-time kernel stacks.
#
# (c) Chris Williams, 2018.
# See LICENSE for usage and copying.

# the kernel is laid out as follows in physical memory on bootup
# (all addresses should be 4KB word aligned, and defined in the target ld script)
#   __kernel_start = base of kernel
#   .
#   . kernel text, data
#   .
#   __kernel_cpu_stack_base = base of space for CPU boot + exception stacks
#   .
#   . N * 8KB * 2 stacks, one for boot, one for exceptions, N = max CPU cores
#   .
#   __kernel_cpu_stack_top = top of stack space
#   __kernel_top_page_base = base of 'top page', 4KB area for kernel variables
#   .
#   . 4KB of variables, locks, etc
#   .
#  __kernel_end = end of kernel in memory
#  __kernel_pg_stack_base = base of upwards growing physical page stacks

# offsets into __kernel_top_page_base area of core global kernel variables
.equ KERNEL_DEBUG_SPIN_LOCK,      (0 * 4)

# must hold KERNEL_PGSTACK_SPIN_LOCK to update KERNEL_PGSTACK_PTR and
# KERNEL_PGSTACK_MAX. KERNEL_PGSTACK_PTR = current phys page stack pointer
# and KERNEL_PGSTACK_MAX is the limit
.equ KERNEL_PGSTACK_SPIN_LOCK,    (1 * 4)
.equ KERNEL_PGSTACK_PTR,          (2 * 4)
.equ KERNEL_PGSTACK_MAX,          (3 * 4)

# number of CPUs running on this system
.equ KERNEL_CPUS_ALIVE,           (4 * 4)
# number of bytes of physical RAM present in this system
.equ KERNEL_PHYS_RAM_SIZE,        (5 * 4)

# each CPU boot stack is 16KB, top 8KB for normal operation.
# lower 8KB for the exception handler.
.equ KERNEL_BOOT_IRQ_STACK_OFFSET, 8 * 1024

# initialize the top page of variables
# corrupts t0, t1, t2
.macro _KERNEL_TOP_PAGE_INIT
  la   t0, __kernel_top_page_base
  la   t1, __kernel_pg_stack_base
  addi t2, t0, KERNEL_PGSTACK_PTR
  sw   t1, (t2)
  addi t2, t0, KERNEL_PGSTACK_MAX
  sw   t1, (t1)
.endm
