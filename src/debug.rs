/*
 * diosix microkernel 'menchi'
 *
 * Functions for debugging the kernel
 *
 * Maintainer: Chris Williams (diosix.org)
 *
 */

/* hook us up with the platform-specific serial port */
extern
{
    fn serial_write_byte(byte: u8);
}

pub fn write_str(s: &str)
{
    for byte in s.bytes()
    {
        unsafe{ serial_write_byte(byte) }
    }
}

