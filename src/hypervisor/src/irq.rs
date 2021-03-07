/* diosix hypervisor code for handling hardware interrupts and software exceptions
 *
 * (c) Chris Williams, 2019-2021.
 *
 * See LICENSE for usage and copying.
 */

use super::scheduler;
use super::capsule;
use super::pcore;
use super::hardware;
use super::service;
use super::error::Cause;

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
        (_, PrivilegeMode::User, IRQCause::IllegalInstruction) |
        (_, PrivilegeMode::Supervisor, IRQCause::IllegalInstruction) =>
        {
            match instructions::emulate(irq.privilege_mode, context)
            {
                EmulationResult::Success => (), /* nothing more to do, return */
                EmulationResult::Yield =>
                {
                    /* instruction was some kind of sleep or pause operation.
                    try to find something else to run in the meantime */
                    scheduler::ping();
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
            /* determine what we need to do from the platform code's decoding */
            if let Some(action) = syscalls::handler(context)
            {
                match action
                {
                    syscalls::Action::Yield => scheduler::ping(),

                    syscalls::Action::Terminate => if let Err(_e) = capsule::destroy_current()
                    {
                        hvalert!("BUG: Failed to terminate currently running capsule ({:?})", _e);
                        syscalls::failed(context, syscalls::ActionResult::Failed);
                    }
                    else
                    {
                        /* find something else to run, this virtual core is dead */
                        scheduler::ping();
                    },

                    syscalls::Action::Restart => if let Err(_e) = capsule::restart_current()
                    {
                        hvalert!("BUG: Failed to restart currently running capsule ({:?})", _e);
                        syscalls::failed(context, syscalls::ActionResult::Failed);
                    }
                    else
                    {
                        /* find something else to run, this virtual core is being replaced */
                        scheduler::ping();
                    },

                    syscalls::Action::TimerIRQAt(target) =>
                    {
                        /* mark this virtual core as awaiting a timer IRQ and
                        schedule a timer interrupt in anticipation */
                        pcore::PhysicalCore::set_virtualcore_timer_target(Some(target));
                        hardware::scheduler_timer_at(target);
                    },

                    /* output a character to the user from this capsule
                       when a console_write capsule calls this, it writes to the console.
                       when a non-console_write capsule calls this, it writes to its console buffer */
                    syscalls::Action::OutputChar(character) => if let Err(_) = capsule::putc(character)
                    {
                        syscalls::failed(context, syscalls::ActionResult::Failed);
                    },

                    /* get a character from the user for this capsule
                       when a console_read capsule calls this, it reads from the console.
                       when a non-console_read capsule calls this, it reads from its console buffer */
                    syscalls::Action::InputChar => match capsule::getc()
                    {
                        /* Linux expects getc()'s value (a character value, or -1 for none available) in
                        the error field of the RISC-V SBI and not in the value field. FIXME: Non-portable.
                        Ref: https://github.com/torvalds/linux/blob/master/arch/riscv/kernel/sbi.c#L92 */
                        Ok(c) => syscalls::result_as_error(context, c as usize),
                        Err(Cause::CapsuleBufferEmpty) => syscalls::result_as_error(context, usize::MAX), /* -1 == nothing to read */
                        Err(_) => syscalls::failed(context, syscalls::ActionResult::Failed)
                    },

                    /* write a character to the given capsule's console buffer.
                       only console_write capsules can call this */
                    syscalls::Action::ConsoleBufferWriteChar(character, capsule_id) => match capsule::console_putc(character, capsule_id)
                    {
                        Ok(_) => (),
                        Err(e) => syscalls::failed(context, match e
                        {
                            Cause::CapsuleBadPermissions => syscalls::ActionResult::Denied,
                            _ => syscalls::ActionResult::Failed
                        })
                    },

                    /* get the next available character from any capsule's console buffer
                       only console_read capsules can call this */
                    syscalls::Action::ConsoleBufferReadChar => match capsule::console_getc()
                    {
                        Ok((character, capsule_id)) => syscalls::result_1extra(context, character as usize, capsule_id),
                        Err(Cause::CapsuleBufferEmpty) => syscalls::result(context, usize::MAX), /* -1 == nothing to read */
                        Err(e) => syscalls::failed(context, match e
                        {
                            Cause::CapsuleBadPermissions => syscalls::ActionResult::Denied,
                            _ => syscalls::ActionResult::Failed
                        })
                    },
                    
                    /* get the next available character from the hypervisor's console/log buffer
                       only console_read capsules can call this */
                    syscalls::Action::HypervisorBufferReadChar => match capsule::hypervisor_getc()
                    {
                        Ok(character) => syscalls::result(context, character as usize),
                        Err(Cause::CapsuleBufferEmpty) => syscalls::result(context, usize::MAX), /* -1 == nothing to read */
                        Err(e) => syscalls::failed(context, match e
                        {
                            Cause::CapsuleBadPermissions => syscalls::ActionResult::Denied,
                            _ => syscalls::ActionResult::Failed
                        })
                    },

                    /* currently running capsule wants to register itself as a service so it can receive
                       and proces requests from other capsules */
                    syscalls::Action::RegisterService(stype_nr) => if let Some(cid) = pcore::PhysicalCore::get_capsule_id()
                    {
                        match service::usize_to_service_type(stype_nr)
                        {
                            Ok(stype) => match service::register(stype, cid)
                            {
                                Ok(_) => (),
                                Err(e) => syscalls::failed(context, match e
                                {
                                    Cause::CapsuleBadPermissions => syscalls::ActionResult::Denied,
                                    _ => syscalls::ActionResult::Failed
                                })
                            },
                            Err(e) => syscalls::failed(context, match e
                            {
                                Cause::ServiceNotFound => syscalls::ActionResult::BadParams,
                                _ => syscalls::ActionResult::Failed
                            })
                        }
                    }
                    else
                    {
                        /* how is this possible? can't find capsule running on this physical core
                           but we're going to try returning to it anyway? */
                        syscalls::failed(context, syscalls::ActionResult::Failed);
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
                PrivilegeMode::Machine =>
                {
                    if severity == IRQSeverity::Fatal
                    {
                        hvalert!("Halting physical CPU core for {:?} at 0x{:x}, stack 0x{:x} integrity {:?}",
                            cause, irq.pc, irq.sp, pcore::PhysicalCore::integrity_check());
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
        IRQCause::MachineTimer =>
        {
            /* make a scheduling decision and raise any supervior-level timer IRQs*/
            scheduler::ping();
            check_supervisor_timer_irq();
        },
        _ => hvdebug!("Unhandled hardware interrupt: {:?}", irq.cause)
    }

    /* clear the interrupt condition */
    platform::irq::acknowledge(irq);
}

/* is the virtual core we're about to run awaiting a timer IRQ?
if so, and if its timer target value has been passed, generate a pending timer IRQ */
fn check_supervisor_timer_irq()
{
    if let Some(target) = pcore::PhysicalCore::get_virtualcore_timer_target()
    {
        match (hardware::scheduler_get_timer_now(), hardware::scheduler_get_timer_frequency())
        {
            (Some(time), Some(freq)) =>
            {
                let current = time.to_exact(freq);
                if current >= target.to_exact(freq)
                {
                    /* create a pending timer IRQ for the supervisor kernel and clear the target */
                    timer::trigger_supervisor_irq();
                    pcore::PhysicalCore::set_virtualcore_timer_target(None);
                }
            },
            (_, _) => ()
        }
    }
}

/* kill the running capsule, alert the user, and then find something else to run.
   if the capsule is important enough to auto-restart-on-crash, try to revive it */
fn fatal_exception(irq: &IRQ)
{
    hvalert!("Terminating running capsule {} for {:?} at 0x{:x}, stack 0x{:x}",
        match pcore::PhysicalCore::this().get_virtualcore_id()
        {
            Some(id) => format!("{}.{}", id.capsuleid, id.vcoreid),
            None => format!("[unknown!]")
        }, irq.cause, irq.pc, irq.sp);

    let mut terminate = false; // when true, destroy the current capsule
    let mut reschedule = false; // when true, we must find another vcore to run

    match capsule::is_current_autorestart()
    {
        Some(true) =>
        {
            hvalert!("Restarting capsule due to auto-restart-on-crash flag");
            if let Err(err) = capsule::restart_current()
            {
                hvalert!("Can't restart capsule ({:?}), letting it die instead", err);
                terminate = true;
            }
            else
            {
                /* the current vcore is no longer running due to restart */
                reschedule = true;
            }
        },
        Some(false) => terminate = true,
        None =>
        {
            hvalert!("BUG: fatal_exception() can't find the running capsule to kill");
            return;
        },
    }

    if terminate == true
    {
        match capsule::destroy_current()
        {
            Err(e) => hvalert!("BUG: Failed to kill running capsule ({:?})", e),
            _ =>
            {
                hvdebug!("Terminated running capsule");

                /* the current vcore is no longer running due to restart */
                reschedule = true;
            }
        }
    }

    if reschedule == true
    {
        /* force a context switch to find another virtual core to run
        because this virtual core no longer exists */
        scheduler::ping();
    }
}