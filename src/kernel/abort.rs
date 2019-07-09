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
    if cfg!(test)
    {
        /* signal to test environment we failed */
        platform::test::end(Err(1));
    }
    else
    {
        /* try to inform the user what went wrong */
        kalert!("Rust runtime panicked unexpectedly");
        match info.location()
        {
            Some(location) =>
            {
                kalert!("... crashed in {}: {}", location.file(), location.line())
            },
            None => kalert!("... crash location unknown")
        };
    }

    /* just halt here */
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
