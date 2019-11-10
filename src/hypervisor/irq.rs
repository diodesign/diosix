/* diosix hypervisor code for handling hardware interrupts and software exceptions
 *
 * (c) Chris Williams, 2019.
 *
 * See LICENSE for usage and copying.
 */

use super::scheduler;
use super::capsule;
use super::cpu;

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
            hvlog!("Environment call from supervisor");
        },

        /* catch fatal supervisor-level exceptions */
        (true, PrivilegeMode::Supervisor, cause) =>
        {
            hvalert!(
                "Fatal exception in {:?}: {:?} at 0x{:x}, stack 0x{:x}",
                PrivilegeMode::Supervisor, cause, irq.pc, irq.sp);

            /* terminate the capsule running on this core */
            if let Some(c) = cpu::Core::capsule()
            {
                capsule::destroy(c);
            }

            /* force a context switch: keep searching for something
               else to run. */
            loop
            {
                if scheduler::run_next() == true
                {
                    break;
                }
            }
        },

        /* catch everything else, halting if fatal */
        (fatal, privilege, cause) =>
        {
            hvalert!(
                "Unhandled exception in {:?}: {:?} at 0x{:x}, stack 0x{:x}",
                privilege, cause, irq.pc, irq.sp);

            /* stop here if we hit an unhandled fatal exception */
            if fatal == true
            {
                hvalert!("Halting after unhandled fatal exception");
                loop {}
            }
        }
    };
}

/* handle hardware interrupt */
fn interrupt(irq: IRQ)
{
    match irq.cause
    {
        /* handle our scheduler's timer by picking another thing to run, if possible */
        IRQCause::HypervisorTimer => { scheduler::run_next(); }, 
        _ => hvlog!("Unhandled hardware interrupt: {:?}", irq.cause)
    };

    /* clear the interrupt condition */
    platform::irq::acknowledge(irq);
}
