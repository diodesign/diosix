/* diosix virtual CPU core management
 *
 * (c) Chris Williams, 2018-2019.
 *
 * See LICENSE for usage and copying.
 */

use super::error::Cause;
use super::capsule::CapsuleID;
use super::scheduler;
use platform::cpu::{SupervisorState, Entry};
use platform::physmem::PhysMemBase;
use platform::timer;

#[derive(Copy, Clone, Debug)]
pub enum Priority
{
    High,
    Normal
}

/* virtual core ID unique to its capsule */
pub type VirtualCoreID = usize;

/* pair a virtual core with its parent capsule using their ID numbers */
#[derive(PartialEq, Eq, Hash)]
pub struct VirtualCoreCanonicalID
{
    pub capsuleid: CapsuleID,
    pub vcoreid: VirtualCoreID
}

/* a virtual core is either in a waiting queue awaiting physical CPU time, or is running and held in a physical CPU core struct.
if you remove a virtual core object from the queue and don't place it back in a queue or Core structure,
then the vcpu will be dropped, deallocated and destroyed. */
pub struct VirtualCore
{
    id: VirtualCoreCanonicalID,
    priority: Priority,
    state: SupervisorState,
    timer_irq_at: Option<timer::TimerValue>
}

impl VirtualCore
{
    /* create a virtual CPU core for a supervisor capsule
       => capsule = ID of the capsule
          core = virtual core ID within the capsule
          entry = pointer to where to begin execution
          dtb = physical address of the device tree blob
                describing the virtual CPU's hardware environment
          priority = virtual core's priority
       <= OK for success, or error code */
    pub fn create(capsuleid: CapsuleID, core: VirtualCoreID, entry: Entry, dtb: PhysMemBase, priority: Priority) -> Result<(), Cause>
    {
        let new_vcore = VirtualCore
        {
            id: VirtualCoreCanonicalID
            {
                capsuleid,
                vcoreid: core
            },
            priority,
            state: platform::cpu::init_supervisor_state(core, entry, dtb),
            timer_irq_at: None
        };

        /* add virtual CPU core to the global waiting list queue */
        scheduler::queue(new_vcore);
        Ok(())
    }

    /* return reference to virtual CPU core's physical CPU state */
    pub fn state_as_ref(&self) -> &SupervisorState
    {
        &self.state
    }
    
    /* return this virtual core's ID within its capsule */
    pub fn get_id(&self) -> VirtualCoreID { self.id.vcoreid }

    /* return virtual CPU core capsule's ID */
    pub fn get_capsule_id(&self) -> CapsuleID { self.id.capsuleid }

    /* return virtual CPU core's priority */
    pub fn get_priority(&self) -> Priority { self.priority }

    /* define value the next timer IRQ should fire for this core.
    measured as value of the clock-on-the-wall for the system, or None for no IRQ */
    pub fn set_timer_irq_at(&mut self, target: Option<timer::TimerValue>)
    {
        self.timer_irq_at = target;
    }

    /* return timer value after which a per-CPU timer IRQ will fire for this core, or None for no IRQ */
    pub fn get_timer_irq_at(&mut self) -> Option<timer::TimerValue>
    {
        self.timer_irq_at
    }
}