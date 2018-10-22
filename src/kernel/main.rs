/* diosix high-level kernel main entry code
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
mod debug;      /* get us some kind of debug output, typically to a serial port */
mod irq;        /* handle hw interrupts and sw exceptions, collectively known as IRQs */
mod abort;      /* implement abort() and panic() handlers */

/* kmain
   The boot CPU core branches here when ready.
   => device_tree_buf = phys RAM pointer to device tree describing the hardware
   <= return to halt kernel on this core
*/
#[no_mangle]
pub extern "C" fn kmain(device_tree_buf: &u8)
{
  klog!("Booting diosix {}", env!("CARGO_PKG_VERSION"));

  /* check we have enough DRAM installed... */
  let dram_size = match platform::get_ram_size(device_tree_buf)
  {
    Some(s) => s,
    None =>
    {
      kalert!("Insufficient RAM or could not determine RAM size");
      return;
    }
  };

  klog!("System RAM: {} bytes", dram_size);
  loop {}
}

/* kwait
   Non-boot CPU cores arrive here when ready to do some work.
   <= return to halt kernel on this core
*/
#[no_mangle]
pub extern "C" fn kwait()
{
  klog!("CPU core alive and waiting");
  loop{}
}
