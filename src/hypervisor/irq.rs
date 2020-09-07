/* diosix hypervisor code for handling hardware interrupts and software exceptions
 *
 * (c) Chris Williams, 2019-2020.
 *
 * See LICENSE for usage and copying.
 */

use super::scheduler;
use super::capsule;
use super::pcore;
use super::hardware;

/* platform-specific code must implement all this */
use platform;
use platform::irq::{IRQContext, IRQType, IRQCause, IRQSeverity, IRQ};
use platform::cpu::PrivilegeMode;
use platform::instructions::{self, EmulationResult};
use platform::syscalls;
use platform::timer;

/* hypervisor_irq_handler
   entry point for hardware interrupts and software exceptions, collectively known as IRQs.
   call down into platform-specific handlers
   => context = platform-specific context of the IRQ, which may be modified depending
   on the IRQ raised. 
*/
#[no_mangle]
pub extern "C" fn hypervisor_irq_handler(mut context: IRQContext)
{
    /* if dispatch() returns an IRQ context then we need to handle it here
    at the high level. if it returns None, the platform-specific code handled it.
    note: the platform library should take care of hardware specfic things like
    catching illegal instructions that can be fixed up and handled transparently */
    if let Some(irq) = platform::irq::dispatch(context)
    {
        match irq.irq_type
        {
            IRQType::Exception => exception(irq, &mut context),
            IRQType::Interrupt => interrupt(irq, &mut context),
        };
    }
}

/* handle software exception */
fn exception(irq: IRQ, context: &mut IRQContext)
{
    match (irq.severity, irq.privilege_mode, irq.cause)
    {
        /* catch illegal instructions we may be able to emulate */
        (_, _, IRQCause::IllegalInstruction) =>
        {
            match instructions::emulate(irq.privilege_mode, context)
            {
                EmulationResult::Success => (), /* nothing more to do, return */
                EmulationResult::Yield =>
                {
                    /* instruction was some kind of sleep or pause operation.
                    try to find something else to run in the meantime */
                    scheduler::run_next(scheduler::SearchMode::CheckOnce);
                },

                /* if we can't handle the instruction,
                kill the capsule and force a context switch.
                TODO: is killing the whole capsule a little extreme? */
                _ => fatal_exception(&irq)
            }
        },

        /* catch environment calls from supervisor mode */
        (_, PrivilegeMode::Supervisor, IRQCause::SupervisorEnvironmentCall) =>
        {
            if let Some(action) = syscalls::handler(context)
            {
                match action
                {
                    syscalls::Action::Terminate => terminate_running_capsule(),
                    syscalls::Action::TimerIRQAt(target) =>
                    {
                        /* mark this virtual core as awaiting a timer IRQ and
                        schedule a timer interrupt in anticipation */
                        pcore::PhysicalCore::set_virtualcore_timer_target(Some(target));
                        scheduler::reschedule_at(target);
                    },
                    _ => if let Some(c) = pcore::PhysicalCore::get_capsule_id()
                    {
                        hvalert!("Capsule {}: Unhandled syscall: {:x?} at 0x{:x}", c, action, irq.pc);
                    }
                    else
                    {
                        hvdebug!("Unhandled syscall: {:x?} at 0x{:x} in unknown capsule", action, irq.pc);
                    }
                }
            }
        },

        /* catch everything else, halting if fatal */
        (severity, privilege, cause) =>
        {
            /* if an unhandled fatal exception reaches us here from the supervisor or user mode,
            kill the capsule. if the hypervisor can't handle its own fatal exception, give up */
            match privilege
            {
                PrivilegeMode::Supervisor | PrivilegeMode::User => if severity == IRQSeverity::Fatal
                {
                    /* TODO: is it wise to blow away the whole capsule for a user exception?
                    the supervisor should really catch its user-level faults */
                    fatal_exception(&irq);
                },
                PrivilegeMode::Machine => if severity == IRQSeverity::Fatal
                {
                    hvalert!("Halting physical CPU core for {:?} at 0x{:x}, stack 0x{:x}", cause, irq.pc, irq.sp);
                    debughousekeeper!(); // flush the debug output
                    loop {}
                }
            }
        }
    }
}

/* handle hardware interrupt */
fn interrupt(irq: IRQ, _: &mut IRQContext)
{
    match irq.cause
    {
        IRQCause::MachineTimer =>
        {
            /* make a scheduling decision */
            scheduler::ping();

            /* is the virtual core we're about to run awaiting a timer IRQ? */
            if let Some(target) = pcore::PhysicalCore::get_virtualcore_timer_target()
            {
                match (hardware::scheduler_get_timer_now(), hardware::scheduler_get_timer_frequency())
                {
                    (Some(t), Some(f)) =>
                    {
                        let current = t.to_exact(f);
                        if current >= target.to_exact(f)
                        {
                            /* create a pending timer IRQ for the supervisor kernel and clear the target */
                            timer::trigger_supervisor_irq();
                            pcore::PhysicalCore::set_virtualcore_timer_target(None);
                        }
                    },
                    (_, _) => ()
                }
            }
        },
        _ => hvdebug!("Unhandled hardware interrupt: {:?}", irq.cause)
    }

    /* clear the interrupt condition */
    platform::irq::acknowledge(irq);
}

/* kill the running capsule, alert the user, and then find something else to run */
fn fatal_exception(irq: &IRQ)
{
    hvalert!("Terminating running capsule for {:?} at 0x{:x}, stack 0x{:x}", irq.cause, irq.pc, irq.sp);

    /* terminate the capsule running on this core */
    terminate_running_capsule();

    /* force a context switch to find another virtual core to run */
    scheduler::run_next(scheduler::SearchMode::MustFind);
}

/* terminate the capsule running on this core */
fn terminate_running_capsule()
{
    match capsule::destroy_current()
    {
        Err(e) => hvalert!("Failed to kill running capsule ({:?})", e),
        _ => ()
    }
}