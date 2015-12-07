/*
 * diosix microkernel 'menchi'
 *
 * Manage software interrupts (SWIs) in x86 systems
 *
 * Maintainer: Chris Williams (diosix.org)
 *
 */

use ::hardware::interrupts;
use errors::KernelInternalError;

const SWI_IRQ_NR: usize = 127;

/* init()
 *
 * Initialize handler for kernel-provided SWIs.
 * 
 */
pub fn init() -> Result<(), KernelInternalError>
{
    kprintln!("[x86] initializing software interrupts");

    /* use vector 127 / 0x7f and allow userspace to trigger it */
    try!(interrupts::set_boot_idt_gate(SWI_IRQ_NR, interrupt_127_handler));
    try!(interrupts::enable_gate_user_access(SWI_IRQ_NR));

    /* TODO: register default driver to these exceptions */

    Ok(())
}

/* let rustc know the interrupt entry handlers are defined elsewhere */
extern
{
    fn interrupt_127_handler();
}

