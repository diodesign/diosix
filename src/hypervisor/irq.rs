/* diosix hypervisor code for handling hardware interrupts and software exceptions
 *
 * (c) Chris Williams, 2019-2020.
 *
 * See LICENSE for usage and copying.
 */

use super::scheduler;
use super::capsule;
use super::pcore;

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
            if let Some(c) = pcore::PhysicalCore::get_capsule_id()
            {
                hvdebug!("Environment call from supervisor-mode capsule ID {}", c);
            }
            else
            {
                hvalert!("BUG: Environment call from supervisor mode but no capsule found");
            }
        },

        /* catch fatal supervisor-level exceptions */
        (true, PrivilegeMode::Supervisor, cause) =>
        {
            hvalert!(
                "Fatal exception in {:?}: {:?} at 0x{:x}, stack 0x{:x}",
                PrivilegeMode::Supervisor, cause, irq.pc, irq.sp);

            /* terminate the capsule running on this core */
            if let Some(c) = pcore::PhysicalCore::get_capsule_id()
            {
                if capsule::destroy(c).is_ok() != true
                {
                    hvalert!("BUG: Could not kill capsule ID {}", c);
                }
            }
            else
            {
                hvalert!("BUG: Exception in supervisor mode but no capsule found");
            }

            /* force a context switch */
            scheduler::run_next(true);
        },

        /* catch everything else, halting if fatal */
        (fatal, privilege, cause) =>
        {
            hvalert!("Unhandled exception in {:?}: {:?} at 0x{:x}, stack 0x{:x}, fatal = {:?}",
                privilege, cause, irq.pc, irq.sp, fatal);
            debughousekeeper!(); // flush the debug output 

            /* stop here if we hit an unhandled fatal exception */
            if fatal == true
            {
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
        IRQCause::HypervisorTimer => scheduler::run_next(false), 
        _ => hvdebug!("Unhandled hardware interrupt: {:?}", irq.cause)
    };

    /* clear the interrupt condition */
    platform::irq::acknowledge(irq);
}
