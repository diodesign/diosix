/* diosix ELF layout for common RV32/RV64 hardware
 *
 * Only requirement is that physical RAM starts at 0x80000000, where the hypervisor is loaded and entered
 *
 * (c) Chris Williams, 2019.
 * See LICENSE for usage and copying.
 */

OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS
{
  /* execution starts at 0x80000000, DRAM base */
  . = 0x80000000;
  __hypervisor_start = .;

  .text : ALIGN(0x1000)
  {
    *(.entry) /* must be first */
    *(.text*)
    *(.rodata*)
  }

  .data : ALIGN(0x1000)
  {
    *(.data*)
  }

  /* this needs to be zeroed */
  .bss : ALIGN(0x1000)
  {
    *(.bss*)
  }

  /* set aligned end to the hypervisor */
  __hypervisor_end = ALIGN(0x1000);
}
