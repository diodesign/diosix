/* kernel's ELF layout for common RV32 hardware
 *
 * Only requirement is that physical RAM starts at 0x80000000, where the kernel is loaded and entered
 *
 * (c) Chris Williams, 2018.
 * See LICENSE for usage and copying.
 */

ENTRY(_start)

SECTIONS
{
  /* execution starts at 0x80000000, DRAM base */
  . = 0x80000000;
  __kernel_start = .;

  /* code and read-only data in physical RAM */
  .text : ALIGN(0x1000)
  {
    *(.entry) /* must be first */
    *(.text*)
    *(.rodata*)
  }

  /* read-write data goes here */
  .bss : ALIGN(0x1000)
  {
    *(.data)
    *(.bss)
  }

  /* set aligned end to the kernel */
  __kernel_end = ALIGN(0x1000);
}
