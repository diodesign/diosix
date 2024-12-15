/* diosix ELF layout for common RV64 hardware
 *
 * Only requirement is that physical RAM starts at 0x80000000, where the hypervisor is loaded and entered
 *
 * (c) Chris Williams, 2024.
 * See LICENSE for usage and copying.
 */

OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS
{
  /* execution starts at 0x80000000, DRAM base */
  . = 0x80000000;
  __hypervisor_start = .;

  .text.entry : ALIGN(0x8)
  {
    KEEP(*(.text.entry))
  }

  .text : ALIGN(0x8)
  {
    *(.text*)
    *(.rodata*)
  }

  .data : ALIGN(0x8)
  {
    *(.data*)
  }

  /* this needs to be zeroed */
  __bss_start = ALIGN(0x8);
  .bss : ALIGN(0x8)
  {
    *(.*bss*)
  }
  __bss_end = ALIGN(0x8);

  /* Move .note.gnu.build-id to the end */
  .note.gnu.build-id : { *(.note.gnu.build-id) }

  /* required for spike. writes and reads to these 64-bit addresses
     are trapped by the simulator and treated specially by spike.
     on non-spike targets, it's a NOP */
  . = ALIGN(0x8);
  tohost = .;
  . += 8;
  fromhost = .;

  /* set aligned end to the hypervisor, round up to nearest page boundary */
  __hypervisor_end = ALIGN(0x1000);

  /DISCARD/ : { *(.note.gnu.property) }
}