/* kernel's ELF layout for SiFive E-series hardware */

ENTRY(_start)

MEMORY
{
  FLASH(rx) : ORIGIN = 0x20000000, LENGTH = 512M
  RAM(rwx) : ORIGIN = 0x80000000, LENGTH = 128K
}

SECTIONS
{
  /* execution starts at 0x20400000 */
  . = ORIGIN(FLASH) + 0x400000;

  /* this is in read-only flash */
  .text :
  {
    *(.text.start)
    *(.text*)
    *(.rodata*)
  }

  . = ORIGIN(RAM);

  /* read-write stuff goes here */
  .bss :
  {
    *(.data)
    *(.bss)
  }

  _end = .;
}
