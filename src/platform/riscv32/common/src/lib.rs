/* RISC-V 32-bit common hardware-specific code
 *
 * (c) Chris Williams, 2018.
 *
 * See LICENSE for usage and copying.
 */

#![no_std]

/* expose architecture common code to platform-specific code */
pub mod devicetree;
pub mod irq;
pub mod physmem;
pub mod cpu;
pub mod timer;