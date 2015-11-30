/* 
 * diosix microkernel 'menchi'
 *
 * Glue for portable Rust kernel code
 *
 * Maintainer: Chris Williams (diosix.org)
 *
 */

#![feature(no_std, lang_items, core_str_ext)]
#![no_std]

/* bring in the kernel debugging features, provides kprintln! and kprint! */
#[macro_use]
mod debug;

/* bare-metal libc, needed to provide various runtime
 * things like memcpy - see: https://crates.io/crates/rlibc */
extern crate rlibc;

/* entry point for our kernel */
#[no_mangle]
pub extern fn kmain()
{
    debug::write_str("hello world!\n");
}

#[lang = "eh_personality"] extern fn eh_personality() {}
#[lang = "panic_fmt"] extern fn panic_fmt() -> ! {loop{}}

