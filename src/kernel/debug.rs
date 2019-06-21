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
use platform::serial;
use error::Cause;

lazy_static!
{
    static ref SERIAL_PHYS_BASE: Mutex<Box<usize>> = Mutex::new(box 0x0);
}

pub static mut DEBUG_LOCK: Spinlock = kspinlock!();

/* tell the compiler the platform-specific serial port code is elsewhere */
extern "C" {
    fn platform_serial_write_byte(byte: u8, addr: usize);
    pub fn platform_cpu_wait();
}

/* top level debug macros */
/* useful messages */
#[macro_export]
macro_rules! klog
{
  ($fmt:expr) => (kprintln!("[-] CPU {}: {}", ::cpu::Core::id(), $fmt));
  ($fmt:expr, $($arg:tt)*) => (kprintln!(concat!("[-] CPU {}: ", $fmt), ::cpu::Core::id(), $($arg)*));
}

/* bad news: bug detection, failures, etc. will bust spinlock to force output */
#[macro_export]
macro_rules! kalert
{
  ($fmt:expr) => (kprintln!("[!] CPU {}: {}", ::cpu::Core::id(), $fmt));
  ($fmt:expr, $($arg:tt)*) => (kprintln!(concat!("[-] CPU {}: ", $fmt), ::cpu::Core::id(), $($arg)*));
}

/* only output if debug build is enabled */
#[macro_export]
#[cfg(debug_assertions)]
macro_rules! kdebug
{
  ($fmt:expr) => (kprintln!("[?] CPU {}: {}", ::cpu::Core::id(), $fmt));
  ($fmt:expr, $($arg:tt)*) => (kprintln!(concat!("[?] CPU {}: ", $fmt), ::cpu::Core::id(), $($arg)*));
}

/* silence debug if disabled */
#[macro_export]
#[cfg(not(debug_assertions))]
macro_rules! kdebug
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

/* low-level macros for kernel-only kprintln and kprint debug output routines */
macro_rules! kprintln
{
  ($fmt:expr) => (kprint!(concat!($fmt, "\n")));
  ($fmt:expr, $($arg:tt)*) => (kprint!(concat!($fmt, "\n"), $($arg)*));
}

macro_rules! kprint
{
  ($($arg:tt)*) =>
  ({
    use core::fmt::Write;

    unsafe { $crate::debug::DEBUG_LOCK.execute(|| {
        $crate::debug::SERIALPORT.write_fmt(format_args!($($arg)*)).unwrap();
      }
    )};
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
    let addr = SERIAL_PHYS_BASE.lock().unwrap();

    for c in s.bytes()
    {
        unsafe {
            platform_serial_write_byte(c, addr);
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
    None => return Cause::DebugFailure
  };

  /* and keep a copy of it */
  let mut base = SERIAL_PHYS_BASE.lock().unwrap();
  *base = addr;
  Ok(())
}