# kernel page zero variables for RV32G targets
#
# Page zero is a 4KB (4096 byte) page of read-write DRAM
# It's the final 4KB page in the first 16MB of physical RAM,
# and placed right above the boot-time kernel stacks.
#
# (c) Chris Williams, 2018.
# See LICENSE for usage and copying.

# reserve the first 16MB of RAM during boot for holding the kernel,
# its payload of executables, stacks and variables
.equ KERNEL_BOOT_TOP,             0x81000000

# reserve the top 4KB for holding locks and other variables
.equ KERNEL_LOCK_PAGE,            0x81000000 - (4 * 1024)
.equ KERNEL_DEBUG_SPIN_LOCK,      KERNEL_LOCK_PAGE + 0x0

# top of the CPU boot stacks sits right under the lock+vars page
.equ KERNEL_BOOT_STACK_TOP,       KERNEL_LOCK_PAGE
