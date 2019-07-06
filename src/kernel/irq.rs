/* diosix machine kernel code for handling hardware interrupts and software exceptions
 *
 * (c) Chris Williams, 2019.
 *
 * See LICENSE for usage and copying.
 */

use scheduler;

/* platform-specific code must implement all this */
use platform;
use platform::irq::{self, IRQContext, IRQType, IRQCause, IRQ};
use platform::cpu::PrivilegeMode;

/* kernel_irq_handler
   entry point for hardware interrupts and software exceptions, collectively known as IRQs.
   call down into platform-specific handlers
   => context = platform-specific context of the IRQ
   <= returns flag word describing IRQ
*/
#[no_mangle]
pub extern "C" fn kirq_handler(context: IRQContext)
{
    let irq = platform::irq::dispatch(context);
    match irq.irq_type
    {
        IRQType::Exception => exception(irq),
        IRQType::Interrupt => interrupt(irq),
    };
}

/* handle software exception */
fn exception(irq: IRQ)
{
    match (irq.fatal, irq.privilege_mode, irq.cause)
    {
        /* catch non-fatal supervisor-level exceptions */
        (false, PrivilegeMode::Supervisor, IRQCause::SupervisorEnvironmentCall) =>
        {
            klog!("Environment call from supervisor")
        },
        /* catch everything else, halting if fatal */
        (fatal, priviledge, cause) =>
        {
            kalert!(
                "Unhandled exception in {:?}: {:?} at 0x{:x}, stack 0x{:x}",
                priviledge, cause, irq.pc, irq.sp);

            /* stop here if we hit an unhandled fatal exception */
            if fatal == true
            {
                kalert!("Halting after unhandled fatal exception");
                loop {}
            }
        }
    }
}

/* handle hardware interrupt */
fn interrupt(irq: IRQ)
{
    match irq.cause
    {
        /* handle our scheduler's timer */
        IRQCause::KernelTimer =>
        {
            scheduler::timer_irq();
        },
        _ => { klog!("Unhandled harwdare interrupt: {:?}", irq.cause) }
    }

    /* clear the interrupt condition */
    irq::acknowledge(irq);
}
