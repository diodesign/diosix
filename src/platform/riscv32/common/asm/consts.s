# machine kernel memory locations and layout for RV32G targets
#
# Top page is a 4KB (4096 byte) page of read-write DRAM
# placed right above the boot-time kernel stacks.
#
# (c) Chris Williams, 2018.
# See LICENSE for usage and copying.

# the kernel is laid out as follows in physical memory on bootup
# (all addresses should be 4KB word aligned, and defined in the target ld script)
#   __kernel_start = base of kernel
#   .
#   . kernel text, data
#   .
#   __kernel_cpu_stack_base = base of space for CPU boot + IRQ stacks + per-CPU variables
#   .
#   . N * 8KB * 2 stacks, one for boot, one for exceptions, N = max CPU cores
#   . plus space for per-CPU variables. layout is as follows:
#   .
#   . variables
#   . ~8KiB of interrupt/exception stack <--- mscratch always points here
#   . 8KiB of boot stack
#   .
#   . once boot is over, and the CPU is running workloads, the IRQ stack rolls into the
#   . boot stack, making it a per-CPU ~16KiB stack plus per-CPU globals at the top
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

# each CPU boot stack is 16KB, bottom 8KB used during startup
# higher 8KB for the interrupt/exception handler, minus space for per-CPU variables
# when startup is over, the IRQ handler can run into the lower 8KBs
.equ KERNEL_BOOT_STACK_OFFSET,    (8 * 1024)

# sitting above the top of the per-CPU IRQ stack, pointed to by mscratch, are per-CPU global
# variables uded to store things like the per-CPU environment pointers, per-CPU heaps, etc
# basically, you load mscratch into sp and use it as the IRQ stack pointer, and also access
# variables above mscratch
.equ  KERNEL_PER_CPU_VAR_SPACE,   (1 * 4) # reserve 1 32-bit word

# offsets from top of IRQ stack into per-CPU variable space
.equ  KERNEL_PER_CPU_HEAP_START,  (0 * 4) # pointer to first page in per-CPU heap

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
