/* diosix RV32/RV64 physical CPU core management
 *
 * (c) Chris Williams, 2019.
 *
 * See LICENSE for usage and copying.
 */

#[allow(dead_code)] 

extern "C"
{
    fn platform_save_supervisor_state(state: &SupervisorState);
    fn platform_load_supervisor_state(state: &SupervisorState);
    fn platform_set_supervisor_return();
}

/* write once during initialization, read many after */
static mut CPU_CORE_COUNT: Option<usize> = None;

/* list of CPU extension initials (yes, I and E are a base) */
const EXTENSIONS: &'static [&'static str] = &["a", "b", "c", "d", "e", "f", "g", "h", "i", "j",
                                              "k", "l", "m", "n", "o", "p", "q", "r", "s", "t",
                                              "u", "v", "w", "x", "y", "z"];

/* flags within CPUFeatures, derived from misa */
const CPUFEATURES_SUPERVISOR_MODE: usize = 1 << 18; /* supervisor mode is implemented */
const CPUFEATURES_USER_MODE: usize       = 1 << 20; /* user mode is implemented */

/* levels of privilege accepted by the hypervisor */
#[derive(Copy, Clone, Debug)]
pub enum PrivilegeMode
{
    Hypervisor, /* machine-mode hypervisor */
    Supervisor, /* supervisor */
    User        /* usermode */
}

pub type Reg = usize;
pub type Entry = usize;

/* describe the CPU state for supervisor-level code */
#[derive(Copy, Clone)]
#[repr(C)]
pub struct SupervisorState
{
    /* supervisor-level CSRs */
    sstatus: Reg,
    stvec: Reg,
    sip: Reg,
    sie: Reg,
    scounteren: Reg,
    sscratch: Reg,
    sepc: Reg,
    scause: Reg,
    stval: Reg,
    satp: Reg,
    pc: Entry,
    sp: Reg,
    /* standard register set (skip x0) */
    registers: [Reg; 31],
}

/* craft a blank supervisor CPU state using the given entry pointers */
pub fn supervisor_state_from(entry: Entry) -> SupervisorState
{
    SupervisorState
    {
        sstatus: 0,
        stvec: 0,
        sip: 0,
        sie: 0,
        scounteren: 0,
        sscratch: 0,
        sepc: 0,
        scause: 0,
        stval: 0,
        satp: 0,
        pc: entry,
        sp: 0,
        registers: [0; 31]
    }
}

/* save the supervisor CPU state to memory. only call from an IRQ context
   as it relies on the IRQ stacked registers. 
   => state = state area to use to store supervisor state */
pub fn save_supervisor_state(state: &SupervisorState)
{
    /* stores CSRs and x1-x31 to memory */
    unsafe { platform_save_supervisor_state(state); }
}

/* load the supervisor CPU state from memory. only call from an IRQ context
   as it relies on the IRQ stacked registers. returning to supervisor mode
   will pick up the new supervisor context.
   => state = state area to use to store supervisor state */
pub fn load_supervisor_state(state: &SupervisorState)
{
    /* stores CSRs and x1-x31 to memory */
    unsafe { platform_load_supervisor_state(state); }
}

/* run in an IRQ context. tweak necessary bits to ensure we return to supervisor mode */
pub fn prep_supervisor_return()
{
    unsafe { platform_set_supervisor_return(); }
}

/* initialize CPU handling code
   => device_tree_buf = device tree to parse 
   <= number of CPU cores in tree, or None for parse error */
pub fn init(device_tree_buf: &u8) -> Option<usize>
{
    match crate::devicetree::get_cpu_count(device_tree_buf)
    {
        Some(c) =>
        {
            unsafe { CPU_CORE_COUNT = Some(c) };
            return Some(c);
        }
        None => return None
    }
}

/* bit masks of CPU features and extenions taken from misa */
pub type CPUFeatures = usize;

/* return the features bit mask of this CPU core */
pub fn features() -> CPUFeatures
{
    return read_csr!(misa) as CPUFeatures;
}

/* check that this CPU core has sufficient features to run code at the given privilege level
   => required = privilege level required
   <= return true if CPU can run code at the required privilege, false if not */
pub fn features_priv_check(required: PrivilegeMode) -> bool
{
    let cpu = read_csr!(misa);

    /* all RISC-V cores provide machine (hypervisor) mode. Diosix requires supervisor mode for user mode */
    match (required, cpu & CPUFEATURES_SUPERVISOR_MODE != 0, cpu & CPUFEATURES_USER_MODE != 0)
    {
        (PrivilegeMode::Hypervisor,    _,    _) => true,
        (PrivilegeMode::Supervisor, true,    _) => true,
        (      PrivilegeMode::User, true, true) => true,
        _ => false
    }
}

/* provide an iterator that lists descriptive strings about this CPU core */
pub fn describe() -> CPUDescriptionIter
{
    CPUDescriptionIter
    {
        state: CPUDescriptionState::Arch,
        misa: read_csr!(misa)
    }
}

/* define the iterator's state machine, allowing us to step from the 
   architecture to extensions to the microarchitecture */
enum CPUDescriptionState
{
    Arch,
    Extension(usize),
    Microarch,
    Done
}

pub struct CPUDescriptionIter
{
    state: CPUDescriptionState,
    misa: usize
}

impl Iterator for CPUDescriptionIter
{
    type Item = &'static str;
    
    fn next(&mut self) -> Option<&'static str>
    {
        match self.state
        {
            /* return whether this is RISCV32 or RISCV64 */
            CPUDescriptionState::Arch =>
            {
                /* ISA width is stored in upper 2 bits of misa */
                let width_shift = if cfg!(target_arch = "riscv32")
                {
                    32 - 2
                }
                else /* assumes RV128 is unsupported */
                {
                    64 - 2
                };

                /* advance the state machine */
                self.state = CPUDescriptionState::Extension(0);

                /* we wouldn't make it this far if we were booting RV32 code on RV64 and vice versa.
                check anyway for diagnostic purposes */
                Some(match self.misa >> width_shift
                {
                    1 => "32-bit RISC-V, ext: ",
                    2 => "64-bit RISC-V, ext: ",
                    _ => "Unsupported RISC-V, ext: "
                })
            },
            CPUDescriptionState::Extension(index) =>
            {
                /* ensure we move onto the next extension, or state if we hit the end (Z, 25) */
                if index < 25
                {
                    self.state = CPUDescriptionState::Extension(index + 1);
                }
                else
                {
                    self.state = CPUDescriptionState::Microarch;
                }

                /* output the initial of the extension if its bit is set in misa */
                if self.misa & (1 << index) != 0
                {
                    Some(EXTENSIONS[index])
                }
                else
                {
                    Some("")
                }
            },
            CPUDescriptionState::Microarch =>
            {
                /* ensure we end this iterator */
                self.state = CPUDescriptionState::Done;

                /* taken from https://github.com/riscv/riscv-isa-manual/blob/master/marchid.md */
                Some(match read_csr!(marchid)
                {
                    1 =>  " Rocket",
                    2 =>  " BOOM",
                    3 =>  " Ariane",
                    4 =>  " RI5CY",
                    5 =>  " Spike",
                    6 =>  " E-Class",
                    7 =>  " ORCA",
                    8 =>  " ORCA",
                    9 =>  " YARVI",
                    10 => " RVBS",
                    11 => " SweRV EH1",
                    12 => " MSCC",
                    13 => " BlackParrot",
                    14 => " BaseJump Manycore",
                    _ => ""
                })
            },
            CPUDescriptionState::Done => None /* end the iterator */
        }
    }
}

/* return number of CPU cores present in the system,
or None for CPU cores not yet counted. */
pub fn nr_of_cores() -> Option<usize>
{
    return unsafe { CPU_CORE_COUNT };
}

/* return the privilege level of the code running before we entereed the machine level */
pub fn previous_privilege() -> PrivilegeMode
{
    /* previous priv level is in bts 11-12 of mstatus */
    match (read_csr!(mstatus) >> 11) & 0b11
    {
        0 => PrivilegeMode::User,
        1 => PrivilegeMode::Supervisor,
        _ => PrivilegeMode::Hypervisor
    }
}