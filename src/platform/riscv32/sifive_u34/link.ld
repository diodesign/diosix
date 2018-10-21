/* kernel's ELF layout for RV32 SiFive U34-series hardware
 * (c) Chris Williams, 2018.
 * See LICENSE for usage and copying.
 */

ENTRY(_start)

SECTIONS
{
  /* execution starts at 0x80000000, DRAM base */
  . = 0x80000000;

  /* code and read-only data in read-write physical RAM */
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

  _end = .;
}
