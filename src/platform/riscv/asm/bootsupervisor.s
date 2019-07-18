# boot supervisor image and initrd inclusion.
# Select the correct vmlinux and rootfs for the target architecture
#
# So far this supports Linux, though any kernel is welcome

.if ptrwidth == 32

.section .bootsupervisor
.incbin "boot/riscv32/vmlinux"

.section initrd
.incbin "boot/riscv32/rootfs.cpio.gz"

.elseif ptrwidth == 64

.section .bootsupervisor
.incbin "boot/riscv64/vmlinux"

.section initrd
.incbin "boot/riscv64/rootfs.cpio.gz"

.else
.error "Only 32-bit and 64-bit RISC-V supported (unexpected pointer width)"
.endif
