/* 
 * diosix microkernel 'menchi'
 *
 * Glue for portable Rust kernel code
 *
 * Maintainer: Chris Williams (diosix.org)
 *
 */

#![feature(no_std, lang_items, core_str_ext, const_fn, asm)]
#![no_std]

/* bring in the kernel debugging features, provides kprintln! and kprint! */
#[macro_use]
mod debug;

/* bare-metal libc, needed to provide various runtime
 * things like memcpy - see: https://crates.io/crates/rlibc */
extern crate rlibc;

/* bare-metal atomic operations because we can't use the std lib.
 * see: https://crates.io/crates/spin */
extern crate spin;

/* library provided by the build target's platform code */
#[cfg(target_arch = "x86_64")]
#[path = "../platform/x86/src/mod.rs"] mod hardware;

/* entry point for our kernel */
#[no_mangle]
pub extern fn kmain()
{
    /* display boot banner */
    kprintln!("diosix {} 'menchi' now running", env!("CARGO_PKG_VERSION"));

    /* initialize interrupts so we can catch exceptions at this early stage */
    hardware::interrupts::init();
}

#[lang = "eh_personality"] extern fn eh_personality() {}
#[lang = "panic_fmt"] extern fn panic_fmt() -> ! {loop{}}

