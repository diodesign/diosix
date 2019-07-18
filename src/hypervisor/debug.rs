/* diosix debugging code
 *
 * By default we write all debug information out to the serial port
 *
 * (c) Chris Williams, 2019.
 *
 * See LICENSE for usage and copying.
 */

use core::fmt;
use lock::Spinlock;
use error::Cause;
use spin::Mutex;
use alloc::boxed::Box;

lazy_static!
{
    static ref SERIAL_PHYS_BASE: Mutex<usize> = Mutex::new(0x0);
    static ref DEBUG_LOCK: Mutex<bool> = Mutex::new(false);
}

/* tell the compiler the platform-specific serial port code is elsewhere */
extern "C" {
    fn platform_serial_write_byte(byte: u8, addr: usize);
    pub fn platform_cpu_wait();
}

/* top level debug macros */
/* useful messages */
#[macro_export]
macro_rules! hvlog
{
  ($fmt:expr) => (hvprintln!("[-] CPU {}: {}", ::cpu::Core::id(), $fmt));
  ($fmt:expr, $($arg:tt)*) => (hvprintln!(concat!("[-] CPU {}: ", $fmt), ::cpu::Core::id(), $($arg)*));
}

/* bad news: bug detection, failures, etc. will bust spinlock to force output */
#[macro_export]
macro_rules! hvalert
{
  ($fmt:expr) => (hvprintln!("[!] CPU {}: {}", ::cpu::Core::id(), $fmt));
  ($fmt:expr, $($arg:tt)*) => (hvprintln!(concat!("[!] CPU {}: ", $fmt), ::cpu::Core::id(), $($arg)*));
}

/* only output if debug build is enabled */
#[macro_export]
#[cfg(debug_assertions)]
macro_rules! hvdebug
{
  ($fmt:expr) => (hvprintln!("[?] CPU {}: {}", ::cpu::Core::id(), $fmt));
  ($fmt:expr, $($arg:tt)*) => (hvprintln!(concat!("[?] CPU {}: ", $fmt), ::cpu::Core::id(), $($arg)*));
}

/* silence debug if disabled */
#[macro_export]
#[cfg(not(debug_assertions))]
macro_rules! hvdebug
{
  ($fmt:expr) => ({});
  ($fmt:expr, $($arg:tt)*) => ({});
}

/* use this to stop rust optimizing away loops and other code */
#[macro_export]
macro_rules! keep_me
{
  () => (unsafe { platform_cpu_wait() /* NOP */ });
}

/* low-level macros for hypervisor-only hvprintln and hvprint debug output routines */
macro_rules! hvprintln
{
  ($fmt:expr) => (hvprint!(concat!($fmt, "\n")));
  ($fmt:expr, $($arg:tt)*) => (hvprint!(concat!($fmt, "\n"), $($arg)*));
}

macro_rules! hvprint
{
  ($($arg:tt)*) =>
  ({
    use core::fmt::Write;

    {
      $crate::debug::DEBUG_LOCK.lock();
      unsafe { $crate::debug::SERIALPORT.write_fmt(format_args!($($arg)*)).unwrap(); }
    }
  });
}

/* create a generic global serial port */
pub struct SerialWriter;
pub static mut SERIALPORT: SerialWriter = SerialWriter {};

impl fmt::Write for SerialWriter
{
    fn write_str(&mut self, s: &str) -> ::core::fmt::Result
    {
        serial_write_string(s);
        Ok(())
    }
}

/* write a string out to the platform's serial port */
pub fn serial_write_string(s: &str)
{
  let addr = SERIAL_PHYS_BASE.lock();

  for c in s.bytes()
  {
      unsafe {
          platform_serial_write_byte(c, **addr);
      }
  }
}

/* initialize the debugging output system
   device_tree => hardware device tree to locate serial device
   <= returns error coe, or OK
*/
pub fn init(device_tree: &u8) -> Result<(), Cause>
{
  /* get address of the serial port hardware */
  let addr = match platform::serial::init(device_tree)
  {
    Some(addr) => addr,
    None => return Err(Cause::DebugFailure)
  };

  /* and keep a copy of it */
  let mut base = SERIAL_PHYS_BASE.lock();
  **base = addr;
  Ok(())
}