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

#[no_mangle]
pub extern fn kmain() {}

#[lang = "eh_personality"] extern fn eh_personality() {}
#[lang = "panic_fmt"] extern fn panic_fmt() -> ! {loop{}}


