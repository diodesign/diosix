/* kernel's ELF layout for Spike-class hardware */

ENTRY(_start)

SECTIONS
{
  . = 0x80000000; /* boot ROM jumps here */

  .text : ALIGN(0x1000)
  {
    *(.text._start)
    *(.text*)
    *(.rodata*)
  }

  .data : ALIGN(0x1000)
  {
    *(.data)
  }

  .bss : ALIGN(0x1000)
  {
    *(COMMON)
    *(.bss)
  }
  
  _end = .;
}



