/* diosix high-level kernel main entry code
 *
 * (c) Chris Williams, 2018.
 *
 * See LICENSE for usage and copying.
 */

#![feature(panic_handler)]
#![no_std]
#![no_main]

use core::panic::PanicInfo;

/* the low-level startup code branches here when ready */
#[no_mangle]
pub extern "C" fn kmain() -> !
{
  serial_write("hello, world from bare metal RISC-V land!!!\n");
  loop {}
}

fn serial_write(s: &str)
{
  for c in s.chars()
  {
    let uart_tx = 0x10013000 as *mut char;
    unsafe { *uart_tx = c; }
  }
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
