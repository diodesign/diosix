/* diosix high-level kernel panic and abort code
 *
 * (c) Chris Williams, 2018.
 *
 * See LICENSE for usage and copying.
 */

use core::panic::PanicInfo;

/* we need to provide these */
#[panic_handler]
pub fn panic(_info: &PanicInfo) -> !
{
  kalert!("Panic handler reached!");
  loop {}
}

#[no_mangle]
pub extern "C" fn abort() -> !
{
  kalert!("Abort handler reached!");
  loop {}
}
