/* 
 * diosix microkernel 'menchi'
 *
 * Linker script for x86 machines
 *
 * Maintainer: Chris Williams <diodesign@gmail.com>
 *
 */


ENTRY(start) /* entry point for the kernel */

SECTIONS {
    . = 1M; /* start from 1MB load point */

    /* ensure the boot section is right at the start for the boot loader to find */
    .boot :
    {
        /* ensure that the multiboot header is at the beginning */
        *(.multiboot_head)
    }

    /* the section that contains our kernel code */
    .text :
    {
        *(.text)
    }
}
