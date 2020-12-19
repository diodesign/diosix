/* diosix high-level hypervisor panic code
 *
 * (c) Chris Williams, 2019-2020.
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
        hvalert!("Rust runtime panicked unexpectedly");
        match info.location()
        {
            Some(location) =>
            {
                hvalert!("... crashed in {}: {}", location.file(), location.line())
            },
            None => hvalert!("... crash location unknown")
        };
    }

    /* just halt here */
    debughousekeeper!();
    loop {}
}
