/* diosix virtual CPU core management
 *
 * (c) Chris Williams, 2018-2019.
 *
 * See LICENSE for usage and copying.
 */

use super::error::Cause;
use super::capsule::CapsuleID;
use platform::cpu::{SupervisorState, Entry};
use super::scheduler;

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
    pub fn create(capsuleid: CapsuleID, core: VirtualCoreID, entry: Entry, priority: Priority) -> Result<(), Cause>
    {
        let new_vcore = VirtualCore
        {
            id: VirtualCoreCanonicalID
            {
                capsuleid: capsuleid,
                vcoreid: core
            },
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
    
    /* return this virtual core's ID within its capsule */
    pub fn get_id(&self) -> VirtualCoreID { self.id.vcoreid }

    /* return virtual CPU core capsule's ID */
    pub fn get_capsule_id(&self) -> CapsuleID { self.id.capsuleid }

    /* return virtual CPU core's priority */
    pub fn get_priority(&self) -> Priority { self.priority }
}
