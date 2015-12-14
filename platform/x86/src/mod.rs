/*
 * diosix microkernel 'menchi'
 *
 * Library of higher-level kernel routines specifically for x86 systems
 *
 * Maintainer: Chris Williams (diosix.org)
 *
 */

use rlibc::memset;

/* x86-specific routines */
mod io;
mod pic;
mod exceptions;
mod swis;
mod multiboot;
mod pages;

/* can be called from the portable kernel */
pub mod physmem;
pub mod interrupts;

