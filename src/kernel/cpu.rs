/* diosix machine kernel's CPU core management
 *
 * (c) Chris Williams, 2018.
 *
 * See LICENSE for usage and copying.
 */

/* platform-specific code must implement all this */
use platform;

/* set to true to unblock SMP cores and allow them to initialize */
static mut SMP_GREEN_LIGHT: bool = false;

/* intiialize CPU core. Prepare it for running supervisor code.
blocks until cleared to continue by the boot CPU
<= returns true if success, or false for failure */
pub fn init() -> bool
{
    /* block until the boot CPU has given us the green light to continue.
    this is unsafe because we're reading without any locking. however,
    there is only one writer (the boot CPU) and multiple readers,
    so there is no data race issue. assumes aligned writes are atomic */
    while !unsafe { SMP_GREEN_LIGHT } { keep_me!(); /* don't optimize away this loop */ }

    return platform::common::cpu::init();
}

/* only the boot CPU should call this: give waiting SMP cores the green light */
pub fn unblock_smp()
{
    unsafe { SMP_GREEN_LIGHT = true; }
}
