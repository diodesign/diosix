/* diosix debug console output code
 *
 * (c) Chris Williams, 2019-2020.
 *
 * See LICENSE for usage and copying.
 */

/* to avoid warnings about super::hardware when qemuprint is active */
#![allow(unused_imports)]

use core::fmt;
use spin::Mutex;
use alloc::string::String;
use super::hardware;

lazy_static!
{
    pub static ref DEBUG_LOCK: Mutex<bool> = Mutex::new(false);
    static ref DEBUG_QUEUE: Mutex<String> = Mutex::new(String::new());
}

/* top level debug macros */
/* useful messages */
#[macro_export]
macro_rules! hvlog
{
    ($fmt:expr) => (hvprintln!("[+] CPU {}: {}", $crate::pcore::PhysicalCore::get_id(), $fmt));
    ($fmt:expr, $($arg:tt)*) => (hvprintln!(concat!("[+] CPU {}: ", $fmt), $crate::pcore::PhysicalCore::get_id(), $($arg)*));
}

/* bad news: bug detection, failures, etc. */
#[macro_export]
macro_rules! hvalert
{
    ($fmt:expr) => (hvprintln!("[!] CPU {}: {}", $crate::pcore::PhysicalCore::get_id(), $fmt));
    ($fmt:expr, $($arg:tt)*) => (hvprintln!(concat!("[!] CPU {}: ", $fmt), $crate::pcore::PhysicalCore::get_id(), $($arg)*));
}

/* only output if debug build is enabled */
#[macro_export]
#[cfg(debug_assertions)]
macro_rules! hvdebug
{
    ($fmt:expr) => (hvprintln!("[?] CPU {}: {}", $crate::pcore::PhysicalCore::get_id(), $fmt));
    ($fmt:expr, $($arg:tt)*) => (hvprintln!(concat!("[?] CPU {}: ", $fmt), $crate::pcore::PhysicalCore::get_id(), $($arg)*));
}

/* silence debug if disabled */
#[macro_export]
#[cfg(not(debug_assertions))]
macro_rules! hvdebug
{
    ($fmt:expr) => ({});
    ($fmt:expr, $($arg:tt)*) => ({});
}

/* don't include any metadata */
#[macro_export]
#[cfg(debug_assertions)]
macro_rules! hvdebugraw
{
    ($fmt:expr) => (hvprint!("{}", $fmt));
    ($fmt:expr, $($arg:tt)*) => (hvprint!(concat!($fmt), $($arg)*));
}

/* silence debug if disabled */
#[macro_export]
#[cfg(not(debug_assertions))]
macro_rules! hvdebugraw
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

macro_rules! debughousekeeper
{
    () => ($crate::debug::drain_queue());
}

/* create a generic debug console writer */
pub struct ConsoleWriter;
pub static mut CONSOLE: ConsoleWriter = ConsoleWriter {};

impl fmt::Write for ConsoleWriter
{
    fn write_str(&mut self, s: &str) -> core::fmt::Result
    {
        /* queue debug output so it can be printed when free to do */
        DEBUG_QUEUE.lock().push_str(s);
        Ok(())
    }
}

/* attempt to empty queue out to the device-tree-defined debug port */
#[cfg(not(feature = "qemuprint"))]
pub fn drain_queue()
{
    let mut queue = DEBUG_QUEUE.lock();
    if hardware::write_debug_string(&queue) == true
    {
        queue.clear();
    }
}

/* force debug output to Qemu's serial port. useful for early debugging */
#[cfg(feature = "qemuprint")]
pub fn drain_queue()
{
    let mut queue = DEBUG_QUEUE.lock();
    for c in queue.as_bytes()
    {
        /* FIXME: hardwired to the RISC-V Qemu serial port */
        unsafe { *(0x10000000 as *mut u8) = *c };
    }

    queue.clear();
}