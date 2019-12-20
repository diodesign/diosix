/* diosix debug console output code
 *
 * (c) Chris Williams, 2019.
 *
 * See LICENSE for usage and copying.
 */

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
    ($fmt:expr) => (hvprintln!("[-] CPU {}: {}", $crate::pcore::PhysicalCore::get_id(), $fmt));
    ($fmt:expr, $($arg:tt)*) => (hvprintln!(concat!("[-] CPU {}: ", $fmt), $crate::pcore::PhysicalCore::get_id(), $($arg)*));
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

macro_rules! hvdrain
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

/* attempt to empty queue out to the debug port */
pub fn drain_queue()
{
    let mut queue = DEBUG_QUEUE.lock();

    if queue.len() > 0 && hardware::write_debug_string(&queue) == true
    {
        queue.clear();
    }
}
