/* diosix debug console output code
 *
 * (c) Chris Williams, 2019.
 *
 * See LICENSE for usage and copying.
 */

use core::fmt;
use spin::Mutex;
use super::error::Cause;
use super::hardware;
use crate::platform::devices::{DeviceType, Device, DeviceReturnData};

lazy_static!
{
    pub static ref DEBUG_LOCK: Mutex<bool> = Mutex::new(false);
}

/* top level debug macros */
/* useful messages */
#[macro_export]
macro_rules! hvlog
{
    ($fmt:expr) => (hvprintln!("[-] CPU {}: {}", $crate::cpu::Core::id(), $fmt));
    ($fmt:expr, $($arg:tt)*) => (hvprintln!(concat!("[-] CPU {}: ", $fmt), $crate::cpu::Core::id(), $($arg)*));
}

/* bad news: bug detection, failures, etc. */
#[macro_export]
macro_rules! hvalert
{
    ($fmt:expr) => (hvprintln!("[!] CPU {}: {}", $crate::cpu::Core::id(), $fmt));
    ($fmt:expr, $($arg:tt)*) => (hvprintln!(concat!("[!] CPU {}: ", $fmt), $crate::cpu::Core::id(), $($arg)*));
}

/* only output if debug build is enabled */
#[macro_export]
#[cfg(debug_assertions)]
macro_rules! hvdebug
{
    ($fmt:expr) => (hvprintln!("[?] CPU {}: {}", $crate::cpu::Core::id(), $fmt));
    ($fmt:expr, $($arg:tt)*) => (hvprintln!(concat!("[?] CPU {}: ", $fmt), $crate::cpu::Core::id(), $($arg)*));
}

/* silence debug if disabled */
#[macro_export]
#[cfg(not(debug_assertions))]
macro_rules! hvdebug
{
    ($fmt:expr) => ({});
    ($fmt:expr, $($arg:tt)*) => ({});
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
            /* we do this little lock dance to ensure the lock isn't immediately dropped by rust */
            let mut lock = $crate::debug::DEBUG_LOCK.lock();
            *lock = true;

            unsafe { $crate::debug::CONSOLE.write_fmt(format_args!($($arg)*)).unwrap(); }
      
            *lock = false;
            drop(lock);
        }
    });
}

/* create a generic debug console writer */
pub struct ConsoleWriter;
pub static mut CONSOLE: ConsoleWriter = ConsoleWriter {};

impl fmt::Write for ConsoleWriter
{
    fn write_str(&mut self, s: &str) -> ::core::fmt::Result
    {
        hardware::access(DeviceType::DebugConsole, | dev | 
        {
            match dev
            {
                Device::DebugConsole(con) => con.write(s),
                _ => ()
            };
            DeviceReturnData::NoData
        });

        Ok(())
    }
}
