/* diosix debug console output code
 *
 * (c) Chris Williams, 2019-2021.
 *
 * See LICENSE for usage and copying.
 */

/* to avoid warnings about super::hardware when qemuprint is active */
#![allow(unused_imports)]

use super::error::Cause;
use core::fmt;
use super::lock::Mutex;
use alloc::vec::Vec;
use alloc::string::String;
use super::hardware;
use super::service;
use super::message;

/* here's the logic for the hypervisor's debug queues
    * all the hvprint macros feed into DEBUG_QUEUE
    * the hypervisor will select a physical CPU core in between workloads to drain DEBUG_QUEUE
    * DEBUG_QUEUE will be drained into two channels: DEBUG_LOG, and the system debug output port
      (typically a serial port) if a user interface capsule isn't running
    * the user interface capsule will drain DEBUG_LOG
    * DEBUG_LOG will have a fixed limit to avoid it chewing up too much RAM
    * if the qemuprint feature is active, the system debug output port will always be the
      Qemu virt serial port regardless of what's in the host hardware's device tree
*/

const DEBUG_LOG_MAX_LEN: usize = 64 * 1024; /* 64KB max length for debug log buffer */

lazy_static!
{
    pub static ref DEBUG_LOCK: Mutex<bool> = Mutex::new("primary debug lock", false);
    static ref DEBUG_QUEUE: Mutex<String> = Mutex::new("debug output queue", String::new());
    static ref DEBUG_LOG: Mutex<Vec<char>> = Mutex::new("debug log buffer", Vec::new());
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

/* don't include any metadata nor add a newline */
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
            let mut hvprint_lock = $crate::debug::DEBUG_LOCK.lock();
            *hvprint_lock = true;

            unsafe { $crate::debug::CONSOLE.write_fmt(format_args!($($arg)*)).unwrap(); }
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
        DEBUG_QUEUE.lock().push_str(s);
        Ok(())
    }
}

/* drain the debug queue into the debug logging buffer, and if no user interface
   is available yet, drain the queue into the system debug output port */
pub fn drain_queue()
{
    /* avoid blocking if we can't write at this time */
    if DEBUG_LOCK.is_locked() == false
    {
        let mut debug_lock = DEBUG_LOCK.lock();
        *debug_lock = true;
        let mut debug_queue = DEBUG_QUEUE.lock();
        let mut debug_log = DEBUG_LOG.lock();

        /* copy the debug queue out to the system debug output port ourselves if there's
           no user interface yet */
        if service::is_registered(service::ServiceType::ConsoleInterface) == false
        {
            if cfg!(feature = "qemuprint")
            {
                /* force debug output to Qemu's serial port. useful for early debugging */
                for c in debug_queue.as_bytes()
                {
                    /* this is the serial port address in qemu's RISC-V virt emulation */
                    if cfg!(target_arch = "riscv64") || cfg!(target_arch = "riscv32")
                    {
                        unsafe { *(0x10000000 as *mut u8) = *c };
                    }
                }
            }
            else
            {
                /* write out the debug info to the registered output interface.
                   bail out now if this failed */
                if hardware::write_debug_string(&debug_queue) == false
                {
                    return;
                }
            }
        }

        /* drain the debug queue to the log buffer so it can be fetched later by the
           user interface service */
        for c in debug_queue.as_str().chars()
        {
            debug_log.push(c);
        }
        debug_queue.clear();

        /* truncate the log buffer if it's too long */
        if debug_log.len() > DEBUG_LOG_MAX_LEN
        {
            let to_truncate = debug_log.len() - DEBUG_LOG_MAX_LEN;
            debug_log.drain(0..to_truncate);
        }
    }
}

/* pick off the next character in the hypervisor log output buffer,
   or None if the buffer is empty */
pub fn get_log_char() -> Option<char>
{
    let mut debug_log = DEBUG_LOG.lock();
    if debug_log.len() > 0
    {
        return Some(debug_log.remove(0));
    }
    None
}