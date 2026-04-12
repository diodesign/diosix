# Minimal Root VM payload
#
# Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
# SPDX-License-Identifier: MIT

.section .rootvm, "a"
.global root_vm_start
.global root_vm_end
.balign 4096
root_vm_start:
.incbin "zig-out/bin/rootvm.elf"
root_vm_end:
