/* Diosix Freestanding S-Mode Guest Bootloader Shim Linker Script
 *
 * Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
 * SPDX-License-Identifier: MIT
 */

OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS
{
    . = 0xe0000000;

    .text : ALIGN(4096) {
        KEEP(*(.text.entry))
        *(.text .text.*)
    }

    .rodata : ALIGN(4096) {
        *(.rodata .rodata.*)
    }

    .data : ALIGN(4096) {
        *(.data .data.*)
        *(.sdata .sdata.*)
    }

    .bss : ALIGN(4096) {
        __bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        . = ALIGN(16);
        __bss_end = .;
    }

    . = ALIGN(4096);
    __stack_bottom = .;
    . += 0x4000; /* 16 KiB S-mode shim stack */
    __stack_top = .;
    __shim_end = .;

    /DISCARD/ : {
        *(.eh_frame*)
        *(.comment)
    }
}
