/* diosix high-level kernel panic and abort code
 *
 * (c) Chris Williams, 2019.
 *
 * See LICENSE for usage and copying.
 */

use core::panic::PanicInfo;

/* we need to provide these */
#[panic_handler]
pub fn panic(info: &PanicInfo) -> !
{
    kalert!("Rust runtime panicked unexpectedly");
    match info.location()
    {
        Some(location) =>
        {
            kalert!("... crashed in {}: {}", location.file(), location.line())
        },
        None => kalert!("... crash location unknown")
    };
    loop
    {}
}

#[no_mangle]
pub extern "C" fn abort() -> !
{
    kalert!("Rust runtime hit the abort button");
    loop
    {}
}
