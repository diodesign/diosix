/* diosix top-level code for handling hardware interrupts and software exceptions
 *
 * (c) Chris Williams, 2018.
 *
 * See LICENSE for usage and copying.
 */

use platform;

/* entry point for software exceptions. call down into platform-specific handlers */
#[no_mangle]
pub extern "C" fn kernel_exception_handler()
{
  klog!("Exception received");
  platform::exception_handler();
}

/* entry point for hardware interrupts. call down into platform-specific handlers */
#[no_mangle]
pub extern "C" fn kernel_interrupt_handler()
{
  klog!("Interrupt received");
  platform::interrupt_handler();
}
