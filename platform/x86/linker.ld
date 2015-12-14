/* 
 * diosix microkernel 'menchi'
 *
 * Linker script for x86 machines
 *
 * Maintainer: Chris Williams <diodesign@gmail.com>
 *
 */

ENTRY(start32) /* entry point for the kernel */

SECTIONS {
    . = 1M; /* start from 1MB load point */
    __kernel_start = .;

    /* the section that contains our kernel code and read-only data */
    .text : ALIGN(0x1000)
    {
      __kernel_ro_start = ALIGN(0x1000);
      KEEP(*(.multiboot_head)) /* keep our multiboot header at the start */
      
      *(.text)
      *(.rodata*)
      __kernel_ro_end = ALIGN(0x1000);
    }

    .data : ALIGN(0x1000)
    {
      __kernel_rw_start = ALIGN(0x1000);
      *(.data)
    }

    .bss : ALIGN(0x1000)
    {
      *(COMMON)
      *(.bss)
      __kernel_rw_end = ALIGN(0x1000);
    }

    __kernel_end = ALIGN(0x1000);
}
