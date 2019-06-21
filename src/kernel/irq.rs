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
    match (irq.fatal, irq.privilege_mode)
    {
        (true, PrivilegeMode::Kernel) =>
        {
            kalert!(
                "Fatal exception in hypervisor: {:?} at 0x{:x}, stack 0x{:x}",
                irq.cause, irq.pc, irq.sp);
            loop {}
        },
        (false, PrivilegeMode::Kernel) =>
        {
            match irq.cause
            {
                IRQCause::SupervisorEnvironmentCall =>
                {
                    klog!("environment call from supervisor");
                },
                _ => ()
            }
        },
        /* fail on everything else */
        (_, priviledge) =>
        {
            kalert!(
                "Unhandled fatal exception (priv {:?}): {:?} at 0x{:x}, stack 0x{:x}",
                priviledge, irq.cause, irq.pc, irq.sp);
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
