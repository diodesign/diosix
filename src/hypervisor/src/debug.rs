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
use spinning::Lazy;
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

pub static DEBUG_LOCK: Lazy<Mutex<bool>> = Lazy::new(|| Mutex::new("primary debug lock", false));
static DEBUG_QUEUE: Lazy<Mutex<String>> = Lazy::new(|| Mutex::new("debug output queue", String::new()));
static DEBUG_LOG: Lazy<Mutex<Vec<char>>> = Lazy::new(|| Mutex::new("debug log buffer", Vec::new()));

/* top level debug macros */
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
    ($fmt:expr) => (hvprint!(concat!($fmt, "\r\n")));
    ($fmt:expr, $($arg:tt)*) => (hvprint!(concat!($fmt, "\r\n"), $($arg)*));
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
    /* write the given string either to the debug queue, which will
       be outputted as normal by the hypervisor or the user interface service,
       or force output through a build-time-selected interface */
    fn write_str(&mut self, s: &str) -> core::fmt::Result
    {
        /* check if we're forcing output to a particular hardware port */
        if cfg!(feature = "qemuprint")
        {
            for c in s.as_bytes()
            {
                if cfg!(target_arch = "riscv64")
                {
                    let tx_register = 0x10000000; /* qemu's RV64 virt UART data register in memory */
                    unsafe { *(tx_register as *mut u8) = *c };
                }
            }
        }
        else if cfg!(feature = "sifiveprint")
        {
            let tx_register = 0x10010000; /* sifive's UART tx register in memory */
            for c in s.as_bytes()
            {
                /* when reading the word-length tx write register, it's zero if we're OK to write to it */
                while unsafe { *(tx_register as *mut u32) } != 0 {}
                unsafe { *(tx_register as *mut u32) = *c as u32 };
            }
        }
        else if cfg!(feature = "htifprint")
        {
            extern "C" { fn platform_write_to_htif(byte: u8); }
            for c in s.as_bytes()
            {
                unsafe { platform_write_to_htif(*c) }
            }
        }
        else
        {
            /* queue the output for printing out later when ready */
            DEBUG_QUEUE.lock().push_str(s);
        }
        Ok(())
    }
}

/* if no user interface is available yet, copy the queue into the system debug output port.
   then regardless of the UI service, drain the debug queue into the debug logging buffer.
   
   if output is being forced to a particular port (eg, using qemuprint or sifiveprint)
   then this function shouldn't have anything to do. a side effect of this is that
   the UI service is then disconnected from the hypervisor's debug output, which means
   there may be conflicts. forcing hypervisor output to a particular interface should
   be used for early debugging, before any capsules are started */
pub fn drain_queue()
{
    /* avoid blocking if we can't write at this time */
    if DEBUG_LOCK.is_locked() == false
    {
        /* acquire main debug lock and pretend to do something to it
           to keep the toolchain happy */
        let mut debug_lock = DEBUG_LOCK.lock();
        *debug_lock = true;

        let mut debug_queue = DEBUG_QUEUE.lock();
        let mut debug_log = DEBUG_LOG.lock();

        /* copy the debug queue out to the system debug output port ourselves if there's no user interface yet */
        if service::is_registered(service::ServiceType::ConsoleInterface) == false
        {
            if hardware::write_debug_string(&debug_queue) == false
            {
                /* we may not even know what hardware is available yet,
                   so bail out and try again later */
                return;
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