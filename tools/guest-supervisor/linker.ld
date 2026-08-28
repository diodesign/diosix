/* Linker script for Diosix guest supervisor payload */
OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS
{
  . = 0x80000000;

  .text : ALIGN(0x1000)
  {
    KEEP(*(.text.entry))
    *(.text*)
  }

  .rodata : ALIGN(0x1000)
  {
    *(.rodata*)
  }

  .data : ALIGN(0x1000)
  {
    *(.data*)
  }

  .bss : ALIGN(0x1000)
  {
    *(.bss*)
    *(COMMON)
    . = ALIGN(16);
    . += 0x10000; /* 64KB stack */
    stack_top = .;
  }

  /DISCARD/ :
  {
    *(.comment)
    *(.eh_frame)
    *(.eh_frame_hdr)
    *(.riscv.attributes)
  }
}
