/*
 * Diosix Minimal Guest Payload (micro-guest)
 * 
 * Lightweight standalone RISC-V 64 guest binary for nested virtualization
 * verification and microVM execution.
 * 
 * Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
 * SPDX-License-Identifier: MIT
 */

.global _start
.section .text
_start:
    /* S-mode entry: a0 contains Hart ID, and a1 contains DTB pointer. */
    la s0, msg
1:
    lb a0, 0(s0)
    beqz a0, 2f
    li a7, 1           /* Call SBI legacy console putchar (extension 0x01). */
    ecall
    addi s0, s0, 1
    j 1b

2:
    /* Cooperatively yield execution time to the hypervisor scheduler. */
    li a7, 0x0A000005  /* Extension ID: EXT_DIOSIX. */
    li a6, 1           /* Function ID: YIELD. */
    ecall
    wfi
    j 2b

.section .rodata
msg:
    .string "\n[diosix-guest] Nested VM online!\n"
