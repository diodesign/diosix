/* diosix virtual CPU core management
 *
 * (c) Chris Williams, 2018-2019.
 *
 * See LICENSE for usage and copying.
 */

use error::Cause;
use capsule::CapsuleID;
use platform::cpu::{SupervisorState, Entry};
use platform::physmem::PhysMemBase;
use scheduler;

#[derive(Copy, Clone, Debug)]
pub enum Priority
{
    High,
    Normal
}

/* virtual core ID unique to its capsule */
pub type VirtualCoreID = usize;

/* a virtual core is either in a waiting queue awaiting physical CPU time, or is runnng and held in a physical CPU core struct.
if you remove a virtual core object from the queue and don't place it back in a queue or Core structure,
then the vcpu will be dropped, deallocated and destroyed. */
pub struct VirtualCore
{
    capsule: CapsuleID,
    core: VirtualCoreID,
    priority: Priority,
    state: SupervisorState
}

impl VirtualCore
{
    /* create a virtual CPU core for a supervisor capsule
       => capsule = ID of the capsule
          core = virtual core ID within the capsule
          entry = pointer to where to begin execution 
          priority = virtual core's priority
       <= OK for success, or error code */
    pub fn create(capsule: CapsuleID, core: VirtualCoreID, entry: Entry, priority: Priority) -> Result<(), Cause>
    {
        let phys_ram = match capsule::get_phys_ram(id.clone())
        {
            Some(r) => r,
            None => return Err(Cause::CapsuleBadName)
        };

        let new_vcore = VirtualCore
        {
            capsule: capsule,
            core: core,
            priority: priority,
            state: platform::cpu::supervisor_state_from(entry)
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
    
    /* return copy of virtual CPU core capsule's ID */
    pub fn capsule(&self) -> CapsuleID
    {
        self.capsule.clone()
    }

    pub fn get_priority(&self) -> Priority { self.priority }
}
