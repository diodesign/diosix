/* diosix ELF layout for common RV32/RV64 hardware
 *
 * Only requirement is that physical RAM starts at 0x80000000, where the kernel is loaded and entered
 *
 * (c) Chris Williams, 2019.
 * See LICENSE for usage and copying.
 */

ENTRY(_start)

SECTIONS
{
  /* execution starts at 0x80000000, DRAM base */
  . = 0x80000000;
  __kernel_start = .;

  /* hypervisor kernel code and read-only data in physical RAM */
  .text : ALIGN(0x1000)
  {
    *(.entry) /* must be first */
    *(.text*)
    *(.rodata*)

    /* builtin-supervisor's shared code */
     __supervisor_shared_start = .;
    *(.sshared*)
    __supervisor_shared_end = .;
  }

  /* hypervisor kernel read-write stack data goes here */
  .bss : ALIGN(0x1000)
  {
    *(.data*)
    *(.bss*)

    /* builtin-supervisor's private static data */
    __supervisor_data_start = .;
    *(.sdata*)
    __supervisor_data_end = .;
  }

  /* set aligned end to the kernel */
  __kernel_end = ALIGN(0x1000);
}
