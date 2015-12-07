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
use ::hardware::interrupts;
use errors::KernelInternalError;

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
const PIC_PRIMARY_VECTOR_BASE: usize = 32;
const PIC_SECONDARY_VECTOR_BASE: usize = 40;

/* remap
 *
 * Move the interrupt vector bases of the system's twin PICs.
 * => primary_base = vector base for the primary PIC
 *    secondary_base = vector base for the secondary PIC
 */
fn remap(primary_base: usize, secondary_base: usize)
{
    let primary_mask = io::read_byte(PIC_PRIMARY_DATA);
    let secondary_mask = io::read_byte(PIC_PRIMARY_DATA);

    /* reinitialise the chipset */
    io::write_byte(PIC_PRIMARY_COMMAND, PIC_ICW1_INIT + PIC_ICW1_ICW4);
    io::write_byte(PIC_SECONDARY_COMMAND, PIC_ICW1_INIT + PIC_ICW1_ICW4);
   
    /* send the new offsets */
    io::write_byte(PIC_PRIMARY_DATA, primary_base as u8);
    io::write_byte(PIC_SECONDARY_DATA, secondary_base as u8);

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
pub fn init() -> Result<(), KernelInternalError>
{
    kprintln!("[x86] initializing basic interrupts");

    /* the pair of PICs start up routing their interrupts to
     * vectors 0x08 to 0x0f and 0x70 to 0x77. map them to
     * somewhere more sensible - the vectors between 32
     * and 47 inclusive.
     */
    remap(PIC_PRIMARY_VECTOR_BASE, PIC_SECONDARY_VECTOR_BASE);

    /* point the IDT entries for the PIC IRQs (32 to 47 inclusive)
     * at the low-level interrupt entry points.
     */
    try!(interrupts::set_boot_idt_gate(PIC_PRIMARY_VECTOR_BASE + 0, interrupt_32_handler));
    try!(interrupts::set_boot_idt_gate(PIC_PRIMARY_VECTOR_BASE + 1, interrupt_33_handler));
    try!(interrupts::set_boot_idt_gate(PIC_PRIMARY_VECTOR_BASE + 2, interrupt_34_handler));
    try!(interrupts::set_boot_idt_gate(PIC_PRIMARY_VECTOR_BASE + 3, interrupt_35_handler));
    try!(interrupts::set_boot_idt_gate(PIC_PRIMARY_VECTOR_BASE + 4, interrupt_36_handler));
    try!(interrupts::set_boot_idt_gate(PIC_PRIMARY_VECTOR_BASE + 5, interrupt_37_handler));
    try!(interrupts::set_boot_idt_gate(PIC_PRIMARY_VECTOR_BASE + 6, interrupt_38_handler));
    try!(interrupts::set_boot_idt_gate(PIC_PRIMARY_VECTOR_BASE + 7, interrupt_39_handler));

    try!(interrupts::set_boot_idt_gate(PIC_SECONDARY_VECTOR_BASE + 0, interrupt_40_handler));
    try!(interrupts::set_boot_idt_gate(PIC_SECONDARY_VECTOR_BASE + 1, interrupt_41_handler));
    try!(interrupts::set_boot_idt_gate(PIC_SECONDARY_VECTOR_BASE + 2, interrupt_42_handler));
    try!(interrupts::set_boot_idt_gate(PIC_SECONDARY_VECTOR_BASE + 3, interrupt_43_handler));
    try!(interrupts::set_boot_idt_gate(PIC_SECONDARY_VECTOR_BASE + 4, interrupt_44_handler));
    try!(interrupts::set_boot_idt_gate(PIC_SECONDARY_VECTOR_BASE + 5, interrupt_45_handler));
    try!(interrupts::set_boot_idt_gate(PIC_SECONDARY_VECTOR_BASE + 6, interrupt_46_handler));
    try!(interrupts::set_boot_idt_gate(PIC_SECONDARY_VECTOR_BASE + 7, interrupt_47_handler));

    /* TODO: register default driver to these IRQs */

    Ok(())
}

/* let rustc know the interrupt entry handlers are defined elsewhere */
extern
{
    fn interrupt_32_handler();
    fn interrupt_33_handler();
    fn interrupt_34_handler();
    fn interrupt_35_handler();
    fn interrupt_36_handler();
    fn interrupt_37_handler();
    fn interrupt_38_handler();
    fn interrupt_39_handler();
    fn interrupt_40_handler();
    fn interrupt_41_handler();
    fn interrupt_42_handler();
    fn interrupt_43_handler();
    fn interrupt_44_handler();
    fn interrupt_45_handler();
    fn interrupt_46_handler();
    fn interrupt_47_handler();
}

