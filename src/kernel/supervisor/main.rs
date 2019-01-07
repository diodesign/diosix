/* diosix supervisor kernel entry code and main loop
 *
 * (c) Chris Williams, 2018.
 *
 * See LICENSE for usage and copying.
 */

#[link_section = ".sshared"]
#[no_mangle]
pub extern "C" fn sentry()
{
    unsafe { asm!("ecall"); }
    unsafe { let var = 0x80000000 as *mut usize; *var = *var + 1; }
    unsafe { asm!("ecall"); }

    loop { }
}
