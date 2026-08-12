# Auto-generated modification hash: 5f1b3515241f6b3c3f7c23d4ebc8716f4f2b8ae214ee4008942e915413d87efe
.section .rootvm, "a"
.global root_vm_start
.global root_vm_end
.balign 4096
root_vm_start:
.incbin "zig-out/bin/rootvm.elf"
root_vm_end:
