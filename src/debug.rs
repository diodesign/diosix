/*
 * diosix microkernel 'menchi'
 *
 * Functions for debugging the kernel
 *
 * Maintainer: Chris Williams (diosix.org)
 *
 */

use core::fmt;
use spin::Mutex; /* can't use the std lib's atomic ops */

/* hook us up with the platform-specific serial port */
extern
{
    fn serial_write_byte(byte: u8);
}

/* create an object representing the debug serial port.
 * this is needed so we can wrap a spinlock around it
 * for thread safety. */
pub static SERIALPORT: Mutex<SerialWriter> = Mutex::new(SerialWriter);

/* create macros for kernel-only kprintln and kprint */
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
        $crate::debug::SERIALPORT.lock().write_fmt(format_args!($($arg)*)).unwrap();
    });
}

pub struct SerialWriter; /* no state to store per serial port */

impl fmt::Write for SerialWriter
{
    fn write_str(&mut self, s: &str) -> ::core::fmt::Result
    {
        for byte in s.bytes()
        {
            unsafe{ serial_write_byte(byte); }
        }
        Ok(())
    }
}

