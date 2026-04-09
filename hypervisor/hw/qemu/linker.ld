/* ELF layout of the hypervisor for Qemu-compatible targets
 *
 * Copyright (c) 2024, 2026 Chris Williams <chrisw@diosix.org>
 * SPDX-License-Identifier: MIT
 *
 */

OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS
{
  /* execution starts at 0x80000000, DRAM base, so place our entry point here */
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

  /* embedded root VM image */
  .rootvm : ALIGN(0x1000)
  {
    __rootvm_start = .;
    KEEP(*(.rootvm))
    __rootvm_end = .;
  }

  /* keep other GNU stuff out of the way */
  /DISCARD/ : { *(.note.gnu.property) }
}