/* diosix RV32/RV64 CPU core management
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

/* bit mask of CPU features */
pub type CPUFeatures = u64;

/* levels of privilege accepted by the kernel */
#[derive(Copy, Clone, Debug)]
pub enum PrivilegeMode
{
    Kernel,     /* machine-mode kernel */
    Supervisor, /* supervisor aka guest kernel */
    User,       /* usermode */
}

pub type Reg = usize;

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
    pc: extern "C" fn () -> (),
    sp: Reg,
    /* standard register set (skip x0) */
    registers: [Reg; 31],
}

/* craft a blank supervisor CPU state using the given entry and stack pointers */
pub fn supervisor_state_from(entry: extern "C" fn () -> (), stack: usize) -> SupervisorState
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
        sp: stack,
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

pub fn features_mask() -> CPUFeatures
{
    return 0;
}

/* return number of CPU cores present in the system,
or None for CPU cores not yet counted. */
pub fn nr_of_cores() -> Option<usize>
{
    return unsafe { CPU_CORE_COUNT };
}
