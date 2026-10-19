/* ELF layout of the hypervisor for QEMU-compatible targets.
 *
 * Copyright (c) 2024, 2026 Chris Williams <chrisw@diosix.org>
 * SPDX-License-Identifier: MIT
 */

OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS
{
  /* Execution starts at 0x80000000 (DRAM base); place entry point here. */
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
    *(.eh_frame_hdr)
    *(.eh_frame)
  }

  /* Start of writable data section (used by PMP RW region boundary). */
  __data_start = ALIGN(0x8);
  .data : ALIGN(0x8)
  {
    *(.data*)
  }

  /* Zeroed during early boot by CPU 0 in entry.s. */
  __bss_start = ALIGN(0x8);
  .bss : ALIGN(0x8)
  {
    *(.bss*)
    *(COMMON)
  }
  __bss_end = ALIGN(0x8);

  /* Place .note.gnu.build-id after BSS. */
  .note.gnu.build-id : { *(.note.gnu.build-id) }

  /* Required for Spike simulator: writes and reads to these 64-bit addresses
     are trapped and treated specially by Spike. On non-Spike targets, NOP. */
  . = ALIGN(0x8);
  tohost = .;
  . += 8;
  fromhost = .;

  /* Embedded Root VM image. */
  .rootvm : ALIGN(0x1000)
  {
    __rootvm_start = .;
    KEEP(*(.rootvm))
    __rootvm_end = .;
  }

  /* Aligned end of the hypervisor footprint, rounded up to page boundary. */
  __hypervisor_end = ALIGN(0x1000);

  /* Discard unneeded GNU property notes. */
  /DISCARD/ : { *(.note.gnu.property) }
}