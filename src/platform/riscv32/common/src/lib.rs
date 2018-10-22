/* RISC-V 32-bit common hardware-specific code
 *
 * (c) Chris Williams, 2018.
 *
 * See LICENSE for usage and copying.
 */

#![no_std]

/* expose architecture common code to platform-specific code */
pub mod devicetree;
pub mod irq;

/* define common structures */

/* levels of privilege accepted by the kernel */
#[derive(Copy, Clone)]
pub enum PrivilegeMode
{
  Kernel,       /* machine-mode kernel */
  Supervisor,   /* supervisor aka guest kernel */
  User          /* usermode */
}

/* describe the type of interruption */
#[derive(Copy, Clone)]
pub enum IRQType
{
  Exception,    /* software-generated interrupt */
  Interrupt     /* hardware-generated interrupt */
}

pub enum IRQCause
{
  /* software interrupt generated from user, supervisor or kernel mode */
  UserSWI, SupervisorSWI, KernelSWI,
  /* hardware timer generated for user, supervisor or kernel mode */
  UserTimer, SupervisorTimer, KernelTimer,
  /* external hw interrupt generated for user, supervisor or kernel mode */
  UserInterrupt, SupervisorInterrupt, KernelInterrupt,

  /* common CPU faults */
  InstructionAlignment, InstructionAccess, IllegalInstruction, InstructionPageFault,
  LoadAlignment, LoadAccess, LoadPageFault, StoreAlignment, StoreAccess, StorePageFault,
  Breakpoint,

  /* other ways to call down from user to supervisor, etc */
  UserEnvironmentCall, SupervisorEnvironmentCall, KernelEnvironmentCall,

  Unknown /* unknown, undefined, or reserved type */
}

/* describe IRQ in high-level, portable terms */
pub struct IRQ
{
  pub fatal: bool,                    /* true if this IRQ means current environment must stop */
  pub privilege_mode: PrivilegeMode,  /* privilege level of the running environment */
  pub irq_type: IRQType,              /* type of the IRQ - sw or hw generated */
  pub cause: IRQCause                 /* cause of this interruption */
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
      _ => "Unknown IRQ"
    }
  }
}

/* Hardware-specific data from low-level IRQ handler.
   Note: register x2 is normally sp but in this case contains the
         top of the IRQ handler stack. Read the interrupted sp from
         mscratch if needed... */
pub struct IRQContext
{
  cause: u32, epc: u32, /* cause code and PC when IRQ fired */
  mtval: u32,           /* IRQ specific information */
  registers: [u32; 32]  /* all 32 registers stacked */
}
