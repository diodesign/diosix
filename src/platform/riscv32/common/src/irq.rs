/* RISC-V 32-bit common exception/interrupt hardware-specific code
 *
 * (c) Chris Williams, 2018.
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
    pub fatal: bool, /* true if this IRQ means current environment must stop */
    pub privilege_mode: ::cpu::PrivilegeMode, /* privilege level of the running environment */
    pub irq_type: IRQType, /* type of the IRQ - sw or hw generated */
    pub cause: IRQCause, /* cause of this interruption */
    pub pc: usize,   /* where in memory this IRQ occured */
    pub sp: usize,   /* stack pointer for interrupted environment */
}

impl IRQ
{
    /* return a string debugging this IRQ's cause */
    pub fn debug_cause(&self) -> &str
    {
        match self.cause
        {
            IRQCause::UserSWI => "Usermode SWI",
            IRQCause::SupervisorSWI => "Supervisor SWI",
            IRQCause::KernelSWI => "Kernel SWI",
            IRQCause::UserTimer => "Usermode timer",
            IRQCause::SupervisorTimer => "Supervisor timer",
            IRQCause::KernelTimer => "Kernel timer",
            IRQCause::UserInterrupt => "Usermode external interrupt",
            IRQCause::SupervisorInterrupt => "Supervisor external interrupt",
            IRQCause::KernelInterrupt => "Kernel external interrupt",
            IRQCause::InstructionAlignment => "Bad instruction alignment",
            IRQCause::InstructionAccess => "Bad instruction access",
            IRQCause::IllegalInstruction => "Illegal instruction",
            IRQCause::InstructionPageFault => "Page fault by instruction fetch",
            IRQCause::LoadAlignment => "Bad memory read alignment",
            IRQCause::LoadAccess => "Bad memory read",
            IRQCause::LoadPageFault => "Page fault by memory read",
            IRQCause::StoreAlignment => "Bad memory write alignment",
            IRQCause::StoreAccess => "Bad memory write",
            IRQCause::StorePageFault => "Page fault by memory write",
            IRQCause::Breakpoint => "Breakpoint",
            IRQCause::UserEnvironmentCall => "Usermode environment call",
            IRQCause::SupervisorEnvironmentCall => "Supervisor environment call",
            IRQCause::KernelEnvironmentCall => "Kernel environment call",
            _ => "Unknown IRQ",
        }
    }
}

/* Hardware-specific data from low-level IRQ handler.
Note: register x2 is normally sp but in this case contains the
      top of the IRQ handler stack. Read the interrupted sp from
      mscratch if needed... */
#[repr(C)]
pub struct IRQContext
{
    cause: u32,
    epc: u32,             /* cause code and PC when IRQ fired */
    mtval: u32,           /* IRQ specific information */
    sp: u32,              /* stack pointer in interrupted envionment */
    registers: [u32; 32], /* all 32 registers stacked */
}

/* dispatch
   Handle incoming IRQs: software exceptions and hardware interrupts
   for the high-level kernel.
   => context = context from the low-level code that picked up the IRQ
   <= return high-level description of the IRQ for the portable kernel
*/
pub fn dispatch(context: IRQContext) -> IRQ
{
    /* convert RISC-V cause codes into generic codes for the kernel.
    the top bit of the cause code is set for interrupts and clear for execeptions */
    let cause_type = match context.cause >> 31
    {
        0 => IRQType::Exception,
        _ => IRQType::Interrupt,
    };
    let cause_mask = (1 << 31) - 1;
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
        privilege_mode: ::cpu::PrivilegeMode::Kernel,
        pc: context.epc as usize,
        sp: context.sp as usize,
    }
}
