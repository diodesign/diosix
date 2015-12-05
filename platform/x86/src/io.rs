/*
 * diosix microkernel 'menchi'
 *
 * Do IO port access on x86 systems
 *
 * Maintainer: Chris Williams (diosix.org)
 *
 */

/* read_byte
 *
 * Read a byte from an IO port.
 * => port = port to read from
 * <= returns byte from the port
 */
pub fn read_byte(port: u16) -> u8
{
    let data: u8;
        
    unsafe
    {
        asm!("in %dx, %al" : "={al}"(data) : "{dx}"(port));
    }

    return data; /* return the byte */
}

/* write_byte
 *
 * Write a byte to an IO port.
 * => port = port to write to
 *    data = byte to write
 */
pub fn write_byte(port: u16, data: u8)
{
    unsafe
    {
        asm!("outb %al, %dx" : : "{al}"(data), "{dx}"(port));
    }
}

