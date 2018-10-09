/* kernel's ELF layout for RV32 SiFive U34-series hardware */

ENTRY(_start)

SECTIONS
{
  /* execution starts at 0x80000000, DRAM base */
  . = 0x80000000;

  /* this is in read-only flash */
  .text : ALIGN(0x1000)
  {
    *(.entry) /* must be first */
    *(.text*)
    *(.rodata*)
  }

  /* read-write stuff goes here */
  .bss : ALIGN(0x1000)
  {
    *(.data)
    *(.bss)
  }

  _end = .;
}
