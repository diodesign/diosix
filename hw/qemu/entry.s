# Prepare Qemu-compatible RV64GC system environment for running the hypervisor proper
#
# Copyright (c) 2024 Chris Williams <chrisw@diosix.org>
# SPDX-License-Identifier: MIT

# _start *must* be the first routine in this file
.section .text.entry
.align 8

.global _start

_start:
    la      sp, 0x80000000 + (1024*1024)
    la      t0, main
    jalr    ra, t0, 0

infinite_loop:
    j       infinite_loop
