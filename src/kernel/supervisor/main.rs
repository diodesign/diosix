/* diosix supervisor kernel entry code and main loop
 *
 * (c) Chris Williams, 2019.
 *
 * See LICENSE for usage and copying.
 */

#[link_section = ".sshared"]
#[no_mangle]
pub extern "C" fn sentry()
{
    unsafe { asm!("ecall"); }

    loop { }
}
