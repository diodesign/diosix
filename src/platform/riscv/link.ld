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

  /* hypervisor code and read-only data in physical RAM */
  .text : ALIGN(0x1000)
  {
    *(.entry) /* must be first */
    *(.text*)
    *(.rodata*)
  }

  /* hypervisor read-write stack data goes here */
  .bss : ALIGN(0x1000)
  {
    *(.data*)
    *(.bss*)
  }

  /* include boot supervisor and initrd payload */
  .payload : ALIGN(0x1000)
  {
    __boot_supervisor_start = .;
    *(.bootsupervisor*)
    __boot_supervisor_end = .;

    __initrd_start = .;
    *(.initrd*)
    __initrd_end = .;
  }

  /* set aligned end to the hypervisor */
  __hypervisor_end = ALIGN(0x1000);
}
