/* diosix RV32G/RV64G common exception/interrupt hardware-specific code
 *
 * (c) Chris Williams, 2019.
 *
 * See LICENSE for usage and copying.
 */

/* describe the type of interruption */
#[derive(Copy, Clone)]
pub enum IRQType
{
    Exception, /* software-generated interrupt */
    Interrupt, /* hardware-generated interrupt */
}

#[derive(Debug, Copy, Clone)]
pub enum IRQCause
{
    /* software interrupt generated from user, supervisor or kernel mode */
    UserSWI,
    SupervisorSWI,
    KernelSWI,
    /* hardware timer generated for user, supervisor or kernel mode */
    UserTimer,
    SupervisorTimer,
    KernelTimer,
    /* external hw interrupt generated for user, supervisor or kernel mode */
    UserInterrupt,
    SupervisorInterrupt,
    KernelInterrupt,

    /* common CPU faults */
    InstructionAlignment,
    InstructionAccess,
    IllegalInstruction,
    InstructionPageFault,
    LoadAlignment,
    LoadAccess,
    LoadPageFault,
    StoreAlignment,
    StoreAccess,
    StorePageFault,
    Breakpoint,

    /* other ways to call down from user to supervisor, etc */
    UserEnvironmentCall,
    SupervisorEnvironmentCall,
    KernelEnvironmentCall,

    Unknown, /* unknown, undefined, or reserved type */
}

/* describe IRQ in high-level, portable terms */
pub struct IRQ
{
    pub fatal: bool, /* true if this IRQ means current container must stop */
    pub privilege_mode: crate::cpu::PrivilegeMode, /* privilege level of the interrupted code */
    pub irq_type: IRQType, /* type of the IRQ - sw or hw generated */
    pub cause: IRQCause, /* cause of this interruption */
    pub pc: usize,   /* where in memory this IRQ occured */
    pub sp: usize,   /* stack pointer for interrupted container */
}

/* Hardware-specific data from low-level IRQ handler.
Note: register x2 is normally sp but in this case contains the
      top of the IRQ handler stack. Read the interrupted sp from
      mscratch if needed... */
#[repr(C)]
pub struct IRQContext
{
    cause: usize,
    epc: usize,             /* cause code and PC when IRQ fired */
    mtval: usize,           /* IRQ specific information */
    sp: usize,              /* stack pointer in interrupted envionment */
    registers: [usize; 32], /* all 32 registers stacked */
}

/* dispatch
   Handle incoming IRQs: software exceptions and hardware interrupts
   for the high-level kernel.
   => context = context from the low-level code that picked up the IRQ
   <= return high-level description of the IRQ for the portable kernel
*/
pub fn dispatch(context: IRQContext) -> IRQ
{
    /* top most bit of mcause sets what caused the IRQ: hardware or software interrupt */
    let cause_shift = if cfg!(target_arch = "riscv32")
    {
        31
    }
    else /* assumes RV128 not supported */
    {
        63
    };

    /* convert RISC-V cause codes into generic codes for the kernel.
    the top bit of the cause code is set for interrupts and clear for execeptions */
    let cause_type = match context.cause >> cause_shift
    {
        0 => IRQType::Exception,
        _ => IRQType::Interrupt,
    };
    let cause_mask = (1 << cause_shift) - 1;
    let (fatal, cause) = match (cause_type, context.cause & cause_mask)
    {
        /* exceptions - some are labeled fatal */
        (IRQType::Exception, 0) => (true, IRQCause::InstructionAlignment),
        (IRQType::Exception, 1) => (true, IRQCause::InstructionAccess),
        (IRQType::Exception, 2) => (true, IRQCause::IllegalInstruction),
        (IRQType::Exception, 3) => (false, IRQCause::Breakpoint),
        (IRQType::Exception, 4) => (true, IRQCause::LoadAlignment),
        (IRQType::Exception, 5) => (true, IRQCause::LoadAccess),
        (IRQType::Exception, 6) => (true, IRQCause::StoreAlignment),
        (IRQType::Exception, 7) => (true, IRQCause::StoreAccess),
        (IRQType::Exception, 8) => (false, IRQCause::UserEnvironmentCall),
        (IRQType::Exception, 9) => (false, IRQCause::SupervisorEnvironmentCall),
        (IRQType::Exception, 11) => (false, IRQCause::KernelEnvironmentCall),
        (IRQType::Exception, 12) => (false, IRQCause::InstructionPageFault),
        (IRQType::Exception, 13) => (false, IRQCause::LoadPageFault),
        (IRQType::Exception, 15) => (false, IRQCause::StorePageFault),

        /* interrupts - none are fatal */
        (IRQType::Interrupt, 0) => (false, IRQCause::UserSWI),
        (IRQType::Interrupt, 1) => (false, IRQCause::SupervisorSWI),
        (IRQType::Interrupt, 3) => (false, IRQCause::KernelSWI),
        (IRQType::Interrupt, 4) => (false, IRQCause::UserTimer),
        (IRQType::Interrupt, 5) => (false, IRQCause::SupervisorTimer),
        (IRQType::Interrupt, 7) => (false, IRQCause::KernelTimer),
        (IRQType::Interrupt, 8) => (false, IRQCause::UserInterrupt),
        (IRQType::Interrupt, 9) => (false, IRQCause::SupervisorInterrupt),
        (IRQType::Interrupt, 11) => (false, IRQCause::KernelInterrupt),
        (_, _) => (false, IRQCause::Unknown),
    };

    /* return structure describing this exception to the high-level kernel */
    IRQ {
        fatal: fatal,
        irq_type: cause_type,
        cause: cause,
        privilege_mode: crate::cpu::previous_privilege(),
        pc: context.epc as usize,
        sp: context.sp as usize,
    }
}

/* clear an interrupt condition so we can return without the IRQ firing immediately. */
pub fn acknowledge(irq: IRQ)
{
    /* clear the appropriate pending bit in mip */
    let bit = match irq.cause
    {
        IRQCause::UserSWI               => 0,
        IRQCause::SupervisorSWI         => 1,
        IRQCause::UserTimer             => 4,
        IRQCause::SupervisorTimer       => 5,
        IRQCause::UserInterrupt         => 8,
        IRQCause::SupervisorInterrupt   => 9,
        _ => return
    };

    /* clear the pending interrupt */
    clear_csr!(mip, 1 << bit);
}
