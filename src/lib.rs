/* 
 * diosix microkernel 'menchi'
 *
 * Glue for portable Rust kernel code
 *
 * Maintainer: Chris Williams <diodesign@gmail.com>
 *
 */

#![feature(no_std, lang_items)]
#![no_std]

#[lang = "eh_personality"] extern fn eh_personality() {}
#[lang = "panic_fmt"] extern fn panic_fmt() -> ! {loop{}}

/* bare-metal libc, needed to provide various runtime
 * things like memcpy - see: https://crates.io/crates/rlibc */
extern crate rlibc;

/* entry point for our kernel */
#[no_mangle]
pub extern fn kmain()
{
    let mut a = 42;
    a += 1;
}

