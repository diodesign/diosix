# diosix hypervisor memory locations and layout for common RV32G/RV64G targets
#
# (c) Chris Williams, 2018-19.
# See LICENSE for usage and copying.

.equ PAGE_SIZE, (4096)

# during interrupts and exceptions, reserve space for 32 registers, 32 or 64 bits wide
.if ptrwidth == 32
.equ  IRQ_REGISTER_FRAME_SIZE,   (32 * 4)   # RV32
.elseif ptrwidth == 64
.equ  IRQ_REGISTER_FRAME_SIZE,   (32 * 8)   # rV64
.else
.error "Only 32-bit and 64-bit RISC-V supported (unexpected pointer width)"
.endif

# the hypervisor is laid out as follows in physical memory on bootup
# (all addresses should be 4KB word aligned, and defined in the target ld script)
#   __hypervisor_start = base of hypervisor
#   .
#   . hypervisor text, read-only data, read-write data / bss
#   .
#   __hypervisor_end = top of the hypervisor's static footprint
#   .
#   . per-CPU slabs of physical memory: each CPU core has...
#   .   exeception / interrupt stack
#   .   page of private variables
#   .   private heap space

# describe per-CPU slab. each slab is 1 << 18 bytes in size = 256KB
# update ../src/physmem.rs PHYS_MEM_PER_CPU if HV_CPU_SLAB_SHIFT changes
.equ HV_CPU_SLAB_SHIFT,         (18)
.equ HV_CPU_SLAB_SIZE,          (1 << HV_CPU_SLAB_SHIFT)
.equ HV_CPU_STACK_BASE,         (0)
.equ HV_CPU_STACK_SIZE,         (32 * 1024)
.equ HV_CPU_PRIVATE_VARS_BASE,  (HV_CPU_STACK_BASE + HV_CPU_STACK_SIZE)
.equ HV_CPU_PRIVATE_VARS_SIZE,  (PAGE_SIZE)
.equ HV_CPU_HEAP_BASE,          (HV_CPU_PRIVATE_PAGE_BASE + HV_CPU_PRIVATE_VARS_BASE)
.equ HV_CPU_HEAP_AREA_SIZE,     (HV_CPU_SLAB_SIZE - HV_CPU_STACK_SIZE - HV_CPU_PRIVATE_VARS_SIZE)
