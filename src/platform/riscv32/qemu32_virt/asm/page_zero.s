# kernel page zero variables for 32-bit Qemu Virt hardware environment
#
# Page zero is a 4KB (4096 byte) page of read-write DRAM
#
# (c) Chris Williams, 2018.
# See LICENSE for usage and copying.

.equ KERNEL_PAGE_ZERO_BASE,       0x80000000
.equ KERNEL_DEBUG_SPIN_LOCK,      KERNEL_PAGE_ZERO_BASE + 0x0
