# Auto-generated modification hash: 9578b32fcf570336731ca64736b684a64f9585a1472325151e6f8e7295556763
.section .rootvm, "a"
.global root_vm_start
.global root_vm_end
.balign 4096
root_vm_start:
.incbin "zig-out/bin/rootvm.elf"
root_vm_end:
