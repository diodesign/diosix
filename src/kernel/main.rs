/* diosix high-level kernel main entry code
 *
 * (c) Chris Williams, 2018.
 *
 * See LICENSE for usage and copying.
 */

/* let the compiler know we're on our own here in bare-metal world */
#![no_std]
#![no_main]
use core::panic::PanicInfo;

/* this will bring in all the hardware-specific code */
extern crate platform;

/* get us some kind of debug output, typically to a serial port */
#[macro_use]
mod debug;

/* kmain
   The selected boot CPU core branches here when ready.
   => cpu_id_nr = CPU core ID we're running on
      device_tree_buf = phys RAM pointer to device tree describing the hardware
   <= return to halt kernel on this core
*/
#[no_mangle]
pub extern "C" fn kmain(_cpu_id_nr: u32, device_tree_buf: &u8)
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
}

/* kwait
   Non-boot CPU cores arrive here when ready to await work to do.
   => cpu_id_nr = CPU core ID we're running on
      device_tree_buf = phys RAM pointer to device tree describing the hardware
   <= return to halt kernel on this core
*/
#[no_mangle]
pub extern "C" fn kwait(_cpu_id_nr: u32)
{
  klog!("CPU core alive and waiting");
  loop{}
}


/* we need to provide these */
#[panic_handler]
#[no_mangle]
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
