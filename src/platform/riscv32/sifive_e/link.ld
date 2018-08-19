/* kernel's ELF layout for SiFive E-series hardware */

ENTRY(_start)

SECTIONS
{
  . = 0x20400000; /* boot ROM jumps here */

  /* this is in read-only flash */
  .text : ALIGN(0x1000)
  {
    *(.text._start)
    *(.text*)
    *(.rodata*)
  }

  /* this is in read-only flash */
  .data : ALIGN(0x1000)
  {
    *(.data)
  }

  /* RAM starts here */
  . = 0x80000000 /*
  .bss : ALIGN(0x1000)
  {
    *(COMMON)
    *(.bss)
  }

  _end = .;
}
