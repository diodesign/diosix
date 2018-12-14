# machine kernel memory locations and layout for common RV32G targets
#
# (c) Chris Williams, 2018.
# See LICENSE for usage and copying.

# the kernel is laid out as follows in physical memory on bootup
# (all addresses should be 4KB word aligned, and defined in the target ld script)
#   __kernel_start = base of kernel
#   .
#   . kernel text, data
#   .
#   __kernel_globals_page_base = base of the kernel's page of global variables
#   .
#   .  the kernel's global variables and locks are here
#   .
#   __kernel_globals_page_top = top of the kernel's page of global variables
#   __kernel_end = top of the kernel's static footprint
#   .
#   . per-CPU slabs of physical memory: each CPU core has...
#   .   exeception / interrupt stack
#   .   page of private variables
#   .   private heap space

# describe per-CPU slab. each slab is 1 << 18 bytes in size = 256KB
.equ KERNEL_CPU_SLAB_SHIFT,         (18)
.equ KERNEL_CPU_SLAB_SIZE,          (1 << KERNEL_CPU_SLAB_SHIFT)
.equ KERNEL_CPU_STACK_SIZE,         (32 * 1024)
.equ KERNEL_CPU_STACK_BASE,         (0)
.equ KERNEL_CPU_PRIVATE_PAGE_SIZE,  (4096)
.equ KENREL_CPU_PRIVATE_PAGE_BASE,  (KERNEL_CPU_STACK_BASE + KERNEL_CPU_STACK_SIZE)
.equ KERNEL_CPU_HEAP_AREA_SIZE,     (KERNEL_CPU_SLAB_SIZE - KERNEL_CPU_STACK_SIZE - KERNEL_CPU_PRIVATE_PAGE_SIZE)
.equ KERNEL_CPU_HEAP_BASE,          (KENREL_CPU_PRIVATE_PAGE_BASE + KERNEL_CPU_PRIVATE_PAGE_SIZE)

# offsets into __kernel_globals_page_base area of core global kernel variables
# it's worth keeping hot variables, like locks, in separate cache lines
# debug output lock
.equ KERNEL_DEBUG_SPIN_LOCK,        (0 * 4)

# number of bytes of physical memory, total
.equ KERNEL_PHYS_MEMORY_SIZE,       (100 * 4)
# number of CPUs awake at boot
.equ KERNEL_CPU_CORE_COUNT,         (101 * 4)
