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
use platform::irq::{IRQContext, IRQType, IRQCause, IRQSeverity, IRQ};
use platform::cpu::PrivilegeMode;
use platform::instructions;
use platform::syscalls;

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
        /* catch supervisor-mode illegal instructions that we may be able to emulate */
        (_, PrivilegeMode::Supervisor, IRQCause::IllegalInstruction) =>
        {
            /* make sure any faults are resolved as the supervisor, not us */
            pcore::PhysicalCore::blame(pcore::Blame::Supervisor);
            if instructions::emulate(irq.privilege_mode, context) != instructions::EmulationResult::Success
            {
                /* if we can't handle the instruction,
                kill the capsule and force a context switch */
                fatal_exception(&irq);
            }

            pcore::PhysicalCore::blame(pcore::Blame::Hypervisor);
        },

        /* catch environment calls from supervisor mode */
        (_, PrivilegeMode::Supervisor, IRQCause::SupervisorEnvironmentCall) =>
        {
            if let Some(_c) = pcore::PhysicalCore::get_capsule_id()
            {
                if let Some(action) = syscalls::handler(context)
                {
                    match action
                    {
                        syscalls::Action::Terminate => terminate_running_capsule(),
                        _ => hvalert!("Capsule {}: Unhandled syscall: {:x?} at 0x{:x}", _c, action, irq.pc)
                    }
                }
            }
            else
            {
                hvalert!("BUG: Environment call from supervisor mode but no capsule found");
            }
        },

        /* catch fatal supervisor-level exceptions: kill the capsule, find something else to run */
        (IRQSeverity::Fatal, PrivilegeMode::Supervisor, _) => fatal_exception(&irq),

        /* catch hypervisor-level illegal instructions we might be able to emulate */
        (_, PrivilegeMode::Hypervisor, IRQCause::IllegalInstruction) =>
        {
            /* if we can't handle the instruction, then we die here */
            if instructions::emulate(irq.privilege_mode, context) != instructions::EmulationResult::Success
            {
                hvalert!("Unhandled illegal instrution in {:?} at 0x{:x}, stack 0x{:x}",
                    irq.privilege_mode, irq.pc, irq.sp);
                debughousekeeper!(); // flush the debug output
                loop {}
            }
        },

        /* catch everything else, halting if fatal */
        (severity, privilege, cause) =>
        {
            match pcore::PhysicalCore::blame_who()
            {
                /* did we fault trying to do something for the supervisor? */
                pcore::Blame::Supervisor =>
                {
                    /* reset any blame back to the hypervisor */
                    pcore::PhysicalCore::blame(pcore::Blame::Hypervisor);

                    hvalert!("Unhandled exception in {:?} as supervisor: {:?} at 0x{:x}, stack 0x{:x}, severity: {:?}",
                        privilege, cause, irq.pc, irq.sp, severity);
                    fatal_exception(&irq);
                },

                /* or did we fault trying to do something for ourselves? */
                pcore::Blame::Hypervisor =>
                {
                    hvalert!("Unhandled exception in {:?}: {:?} at 0x{:x}, stack 0x{:x}, severity: {:?}",
                        privilege, cause, irq.pc, irq.sp, severity);

                    /* stop here if we hit an unhandled fatal exception */
                    if severity == IRQSeverity::Fatal
                    {
                        hvalert!("Halting hypervisor on this physical core");
                        debughousekeeper!(); // flush the debug output
                        loop {}
                    }
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
        /* handle our scheduler's timer by picking something thing to run, if possible */
        IRQCause::HypervisorTimer => scheduler::run_next(scheduler::SearchMode::CheckOnce), 
        _ => hvdebug!("Unhandled hardware interrupt: {:?}", irq.cause)
    }

    /* clear the interrupt condition */
    platform::irq::acknowledge(irq);
}

/* kill the running capsule, alert the user, and then find something else to run */
fn fatal_exception(irq: &IRQ)
{
    hvalert!(
        "Fatal exception in {:?}: {:?} at 0x{:x}, stack 0x{:x}",
        irq.privilege_mode, irq.cause, irq.pc, irq.sp);

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