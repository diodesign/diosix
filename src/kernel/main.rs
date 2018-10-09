/* diosix high-level kernel main entry code
 *
 * (c) Chris Williams, 2018.
 *
 * See LICENSE for usage and copying.
 */

#![no_std]
#![no_main]

use core::panic::PanicInfo;

#[macro_use]
mod debug;

/* the low-level startup code branches here when ready */
#[no_mangle]
pub extern "C" fn kmain()
{
  kprintln!("\nBooting diosix {}...\n\n", env!("CARGO_PKG_VERSION"));
}

/* we're on our own here, so we need to provide these */
#[panic_handler]
#[no_mangle]
pub fn panic(_info: &PanicInfo) -> !
{
  loop {}
}

#[no_mangle]
pub extern "C" fn abort() -> !
{
  loop {}
}
