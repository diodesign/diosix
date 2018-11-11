/* kernel's ELF layout for common SMP RV32 hardware
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

  /* code and read-only data in physical RAM */
  .text : ALIGN(0x1000)
  {
    *(.entry) /* must be first */
    *(.text*)
    *(.rodata*)
  }

  /* read-write data goes here */
  .bss : ALIGN(0x1000)
  {
    *(.data)
    *(.bss)
  }

  /* read-write special reserved memory here */
  .reserved : ALIGN(0x1000)
  {
    /* reserve pages for 16KB per-CPU stacks, max 8 CPU cores */
    __kernel_cpu_stack_base = .;
    __kernel_cpu_stack_top = __kernel_cpu_stack_base + (16 * 1024 * 8);

    /* reserve a page in memory for the kernel's variables + locks */
    __kernel_top_page_base = __kernel_cpu_stack_top;

    /* start of physical page stacks, growing upwards */
    __kernel_pg_stack_base = __kernel_top_page_base + 0x1000;

    /* end of fixed kernel components */
    __kernel_end = __kernel_pg_stack_base;
  }
}
