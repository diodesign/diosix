/* kernel's ELF layout for RV32 Qemu Virt hardware environment
 * (c) Chris Williams, 2018.
 * See LICENSE for usage and copying.
 */

ENTRY(_start)

SECTIONS
{
  /* execution starts at 0x80000000, DRAM base */
  . = 0x80000000;

  /* this is in read-write physical RAM */
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
