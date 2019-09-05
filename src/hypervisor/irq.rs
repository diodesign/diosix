/* diosix hypervisor code for handling hardware interrupts and software exceptions
 *
 * (c) Chris Williams, 2019.
 *
 * See LICENSE for usage and copying.
 */

use super::scheduler;

/* platform-specific code must implement all this */
use platform;
use platform::irq::{IRQContext, IRQType, IRQCause, IRQ};
use platform::cpu::PrivilegeMode;

/* hypervisor_irq_handler
   entry point for hardware interrupts and software exceptions, collectively known as IRQs.
   call down into platform-specific handlers
   => context = platform-specific context of the IRQ
   <= returns flag word describing IRQ
*/
#[no_mangle]
pub extern "C" fn hypervisor_irq_handler(context: IRQContext)
{
    let debug_context = context;
    let irq = platform::irq::dispatch(context);
    match irq.irq_type
    {
        IRQType::Exception => { hvlog!("Exception context: {:x?}", &debug_context); exception(irq) },
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
            hvlog!("Environment call from supervisor")
        },
        /* catch everything else, halting if fatal */
        (fatal, priviledge, cause) =>
        {
            hvalert!(
                "Unhandled exception in {:?}: {:?} at 0x{:x}, stack 0x{:x}",
                priviledge, cause, irq.pc, irq.sp);

            /* stop here if we hit an unhandled fatal exception */
            if fatal == true
            {
                hvalert!("Halting after unhandled fatal exception");
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
        IRQCause::HypervisorTimer =>
        {
            scheduler::timer_irq();
        },
        _ => { hvlog!("Unhandled harwdare interrupt: {:?}", irq.cause) }
    }

    /* clear the interrupt condition */
    platform::irq::acknowledge(irq);
}
