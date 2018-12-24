/* kernel's ELF layout for common RV32 hardware
 *
 * Only requirement is that physical RAM starts at 0x80000000, where the kernel is loaded and entered
 *
 * (c) Chris Williams, 2018.
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
  }

  /* hypervisor kernel read-write stack data goes here */
  .bss : ALIGN(0x1000)
  {
    *(.data)
    *(.bss)
  }

  /* built-in supervisor kernel */
  .supervisor : ALIGN(0x1000)
  {
    __supervisor_code_start = .;
    *(.supervisortext*)
    __supervisor_code_end = .;
    __supervisor_data_start = .;
    *(.supervisordata*)
    __supervisor_data_end = .;
  }

  /* set aligned end to the kernel */
  __kernel_end = ALIGN(0x1000);
}
