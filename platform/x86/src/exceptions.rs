/*
 * diosix microkernel 'menchi'
 *
 * Manage processor exceptions in x86 systems
 *
 * Maintainer: Chris Williams (diosix.org)
 *
 */

use ::hardware::interrupts;
use errors::KernelInternalError;

/* init()
 *
 * Initialize the handlers for the boot CPU's exceptions.
 * 
 */
pub fn init() -> Result<(), KernelInternalError>
{
    kprintln!("[x86] initializing processor exceptions");

    /* point the IDT entries for the boot CPU's exceptions to handlers. 
     * that's interrupts 0 to 31 inclusive. */
    try!(interrupts::set_boot_idt_gate(0, interrupt_0_handler));
    try!(interrupts::set_boot_idt_gate(1, interrupt_1_handler));
    try!(interrupts::set_boot_idt_gate(2, interrupt_2_handler));
    try!(interrupts::set_boot_idt_gate(3, interrupt_3_handler));
    try!(interrupts::set_boot_idt_gate(4, interrupt_4_handler));
    try!(interrupts::set_boot_idt_gate(5, interrupt_5_handler));
    try!(interrupts::set_boot_idt_gate(6, interrupt_6_handler));
    try!(interrupts::set_boot_idt_gate(7, interrupt_7_handler));
    try!(interrupts::set_boot_idt_gate(8, interrupt_8_handler));
    /* there is no handler for interrupt 9 */

    try!(interrupts::set_boot_idt_gate(10, interrupt_10_handler));
    try!(interrupts::set_boot_idt_gate(11, interrupt_11_handler));
    try!(interrupts::set_boot_idt_gate(12, interrupt_12_handler));
    try!(interrupts::set_boot_idt_gate(13, interrupt_13_handler));
    try!(interrupts::set_boot_idt_gate(14, interrupt_14_handler));
    /* there is no handler for interrupt 15 */
    try!(interrupts::set_boot_idt_gate(16, interrupt_16_handler));
    try!(interrupts::set_boot_idt_gate(17, interrupt_17_handler));
    try!(interrupts::set_boot_idt_gate(18, interrupt_18_handler));
    try!(interrupts::set_boot_idt_gate(19, interrupt_19_handler));
    
    try!(interrupts::set_boot_idt_gate(20, interrupt_20_handler));
    try!(interrupts::set_boot_idt_gate(21, interrupt_21_handler));
    try!(interrupts::set_boot_idt_gate(22, interrupt_22_handler));
    try!(interrupts::set_boot_idt_gate(23, interrupt_23_handler));
    try!(interrupts::set_boot_idt_gate(24, interrupt_24_handler));
    try!(interrupts::set_boot_idt_gate(25, interrupt_25_handler));
    try!(interrupts::set_boot_idt_gate(26, interrupt_26_handler));
    try!(interrupts::set_boot_idt_gate(27, interrupt_27_handler));
    try!(interrupts::set_boot_idt_gate(28, interrupt_28_handler));
    try!(interrupts::set_boot_idt_gate(29, interrupt_29_handler));

    try!(interrupts::set_boot_idt_gate(30, interrupt_30_handler));
    /* there is no handler for interrupt 31 */


    /* TODO: register default driver to these exceptions */

    Ok(())
}

/* let rustc know the interrupt entry handlers are defined elsewhere */
extern
{
    fn interrupt_0_handler();
    fn interrupt_1_handler();
    fn interrupt_2_handler();
    fn interrupt_3_handler();
    fn interrupt_4_handler();
    fn interrupt_5_handler();
    fn interrupt_6_handler();
    fn interrupt_7_handler();
    fn interrupt_8_handler();

    fn interrupt_10_handler();
    fn interrupt_11_handler();
    fn interrupt_12_handler();
    fn interrupt_13_handler();
    fn interrupt_14_handler();
    fn interrupt_16_handler();
    fn interrupt_17_handler();
    fn interrupt_18_handler();
    fn interrupt_19_handler();
    
    fn interrupt_20_handler();
    fn interrupt_21_handler();
    fn interrupt_22_handler();
    fn interrupt_23_handler();
    fn interrupt_24_handler();
    fn interrupt_25_handler();
    fn interrupt_26_handler();
    fn interrupt_27_handler();
    fn interrupt_28_handler();
    fn interrupt_29_handler();

    fn interrupt_30_handler();
}

