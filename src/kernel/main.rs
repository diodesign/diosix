/* diosix machine/hypervisor kernel main entry code
 *
 * (c) Chris Williams, 2018.
 *
 * See LICENSE for usage and copying.
 */

/* let the compiler know we're on our own here in bare-metal world */
#![no_std]
#![no_main]

/* this will bring in all the hardware-specific code */
extern crate platform;

#[macro_use]
mod debug; /* get us some kind of debug output, typically to a serial port */
mod abort; /* implement abort() and panic() handlers */
mod heap;  /* manage machine kernel's heap memory */
mod irq;   /* handle hw interrupts and sw exceptions, collectively known as IRQs */
mod physmem; /* manage physical memory */

/* funciton naming note: machine kernel entry points start with a k, such as kmain,
kwait, kirq_handler. supervisor kernel entry points start with an s, such as smain.
generally, kernel = machine/hypervisor kernel, supervisor = supervisor kernel. */

/* pointer sizes: do not assume this is a 32-bit or 64-bit system. it could be either.
stick to usize as much as possible */

/* kmain
   The boot CPU core branches here when ready.
   This code runs at the machine/hypervisor level, with physical memory access.
   Its job is to create environments in which supervisor kernels run. Thus the kernel is
   split into two halves: a machine/hv lower half, and an upper half supervisor that
   manages user-mode code.

   => device_tree_buf = phys RAM pointer to device tree describing the hardware
   <= return to halt kernel on this core
*/
#[no_mangle]
pub extern "C" fn kmain(device_tree_buf: &u8)
{
    klog!("Welcome to diosix {}", env!("CARGO_PKG_VERSION"));

    /* set up the physical memory managemenwt */
    match physmem::init(device_tree_buf)
    {
        Some(s) => klog!(
            "Total physical memory avilable: {} MiB ({} bytes)",
            s / 1024 / 1024,
            s
        ),
        None =>
        {
            kalert!("Insufficient physical memory, halting.");
            return;
        }
    };
}

/* kwait
   Non-boot CPU cores arrive here when ready to do some work.
   <= return to halt kernel on this core
*/
#[no_mangle]
pub extern "C" fn kwait()
{
    klog!("CPU core alive and waiting");
}
