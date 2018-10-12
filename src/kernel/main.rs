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
   the low-level startup code branches here when ready.
   => cpu_id_nr = CPU core ID we're running on
      device_tree_buf = phys RAM pointer to device tree describing the hardware
   <= return to halt kernel on this core
*/
#[no_mangle]
pub extern "C" fn kmain(cpu_id_nr: u32, device_tree_buf: &u8)
{
  kprintln!("\nBooting diosix {} on CPU {}", env!("CARGO_PKG_VERSION"), cpu_id_nr);

  /* check we have enough DRAM installed... */
  let dram_size = match platform::get_ram_size(device_tree_buf)
  {
    Some(s) => s,
    None =>
    {
      kprintln!("FAIL: Insufficient RAM or could not determine RAM size");
      return;
    }
  };

  kprintln!("System RAM: {} bytes\n", dram_size);
}



/* we need to provide these */
#[panic_handler]
#[no_mangle]
pub fn panic(_info: &PanicInfo) -> !
{
  kprintln!("WTF: Panic handler reached!");
  loop {}
}

#[no_mangle]
pub extern "C" fn abort() -> !
{
  kprintln!("WTF: Abort handler reached!");
  loop {}
}
