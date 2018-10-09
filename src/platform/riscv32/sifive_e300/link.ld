/* kernel's ELF layout for SiFive E300-series hardware */

ENTRY(_start)

SECTIONS
{
  /* execution starts at 0x20400000 */
  . = 0x20400000;

  /* this is in read-only flash */
  .text : ALIGN(0x1000)
  {
    *(.entry) /* must be first */
    *(.text*)
    *(.rodata*)
  }

  . = 0x80000000;
  /* read-write stuff goes here */
  .bss : ALIGN(0x1000)
  {
    *(.data)
    *(.bss)
  }

  _end = .;
}
