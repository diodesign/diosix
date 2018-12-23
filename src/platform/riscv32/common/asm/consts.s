# machine kernel memory locations and layout for common RV32G targets
#
# (c) Chris Williams, 2018.
# See LICENSE for usage and copying.

.equ PAGE_SIZE, (4096)

# the kernel is laid out as follows in physical memory on bootup
# (all addresses should be 4KB word aligned, and defined in the target ld script)
#   __kernel_start = base of kernel
#   .
#   . kernel text, read-only data, read-write data / bss
#   .
#   __kernel_end = top of the kernel's static footprint
#   .
#   . per-CPU slabs of physical memory: each CPU core has...
#   .   exeception / interrupt stack
#   .   page of private variables
#   .   private heap space

# describe per-CPU slab. each slab is 1 << 18 bytes in size = 256KB
# update ../src/physmem.rs PHYS_MEM_PER_CPU if KERNEL_CPU_SLAB_SHIFT changes
.equ KERNEL_CPU_SLAB_SHIFT,         (18)
.equ KERNEL_CPU_SLAB_SIZE,          (1 << KERNEL_CPU_SLAB_SHIFT)
.equ KERNEL_CPU_STACK_BASE,         (0)
.equ KERNEL_CPU_STACK_SIZE,         (32 * 1024)
.equ KENREL_CPU_PRIVATE_VARS_BASE,  (KERNEL_CPU_STACK_BASE + KERNEL_CPU_STACK_SIZE)
.equ KERNEL_CPU_PRIVATE_VARS_SIZE,  (PAGE_SIZE)
.equ KERNEL_CPU_HEAP_BASE,          (KENREL_CPU_PRIVATE_PAGE_BASE + KENREL_CPU_PRIVATE_VARS_BASE)
.equ KERNEL_CPU_HEAP_AREA_SIZE,     (KERNEL_CPU_SLAB_SIZE - KERNEL_CPU_STACK_SIZE - KERNEL_CPU_PRIVATE_VARS_SIZE)
