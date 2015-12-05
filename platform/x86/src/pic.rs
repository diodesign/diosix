/*
 * diosix microkernel 'menchi'
 *
 * Manage the legacy Intel 8259 PICs in x86 systems
 *
 * Reference: https://github.com/diodesign/diosix-legacy/blob/master/kernel/ports/i386/hw/pic.c
 *            http://wiki.osdev.org/8259_PIC
 *
 * Maintainer: Chris Williams (diosix.org)
 *
 */

use ::hardware::io;

/* PIC IO addresses */
const PIC_PRIMARY_IOADDR:    u16 = 0x20; /* IO address base of the primary PIC */
const PIC_SECONDARY_IOADDR:  u16 = 0xa0; /* IO address base of the secondary PIC */

const PIC_PRIMARY_COMMAND:   u16 = PIC_PRIMARY_IOADDR; /* define primary PIC's registers */
const PIC_PRIMARY_DATA:      u16 = PIC_PRIMARY_IOADDR + 1;

const PIC_SECONDARY_COMMAND: u16 = PIC_SECONDARY_IOADDR; /* define secondary PIC's registers */
const PIC_SECONDARY_DATA:    u16 = PIC_SECONDARY_IOADDR + 1;

/* PIC commands */
const PIC_ICW1_ICW4:         u8 = 0x01; /* ICW4 (not) needed */
const PIC_ICW1_INIT:         u8 = 0x10; /* Initialization - required! */
 
const PIC_ICW4_8086:         u8 = 0x01; /* 8086/88 (MCS-80/85) mode */

/* run the primary PIC from interrupt vector 32 to 39 inclusive.
 * run the secondary PIC from interrupt vector 40 to 47 inclusive.
 */
const PIC_PRIMARY_VECTOR_BASE: u8 = 32;
const PIC_SECONDARY_VECTOR_BASE: u8 = 40;

/* remap
 *
 * Move the interrupt vector bases of the system's twin PICs.
 * => primary_base = vector base for the primary PIC
 *    secondary_base = vector base for the secondary PIC
 */
fn remap(primary_base: u8, secondary_base: u8)
{
    let primary_mask = io::read_byte(PIC_PRIMARY_DATA);
    let secondary_mask = io::read_byte(PIC_PRIMARY_DATA);

    /* reinitialise the chipset */
    io::write_byte(PIC_PRIMARY_COMMAND, PIC_ICW1_INIT + PIC_ICW1_ICW4);
    io::write_byte(PIC_SECONDARY_COMMAND, PIC_ICW1_INIT + PIC_ICW1_ICW4);
   
    /* send the new offsets */
    io::write_byte(PIC_PRIMARY_DATA, primary_base);
    io::write_byte(PIC_SECONDARY_DATA, secondary_base);

    /* complete the reinitialisation sequence */
    io::write_byte(PIC_PRIMARY_DATA, 4); /* there's a secondary PIC at IRQ2 */
    io::write_byte(PIC_SECONDARY_DATA, 2); /* secondary PIC's cascade identity */
    io::write_byte(PIC_PRIMARY_DATA, PIC_ICW4_8086);
    io::write_byte(PIC_SECONDARY_DATA, PIC_ICW4_8086);

    /* restore saved masks */
    io::write_byte(PIC_PRIMARY_DATA, primary_mask);
    io::write_byte(PIC_SECONDARY_DATA, secondary_mask);
}

/* init()
 *
 * Initialize the legacy PICs in x86 chipsets. Move them out of
 * the way of the CPU's exceptions.
 *
 */
pub fn init()
{
    kprintln!("[pic] Initializing basic interrupts");

    /* the pair of PICs start up routing their interrupts to
     * vectors 0x08 to 0x0f and 0x70 to 0x77. map them to
     * somewhere more sensible - the vectors between 32
     * and 47 inclusive.
     */
    remap(PIC_PRIMARY_VECTOR_BASE, PIC_SECONDARY_VECTOR_BASE);


}

