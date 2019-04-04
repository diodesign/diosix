/* diosix thread management
 *
 * (c) Chris Williams, 2018-2019.
 *
 * See LICENSE for usage and copying.
 */

use error::Cause;
use container::{get_phys_ram, ContainerID};
use platform::common::cpu::{supervisor_state_from, SupervisorState};
use physmem::PhysMemBase;
use scheduler;

#[derive(Copy, Clone, Debug)]
pub enum Priority
{
    High,
    Normal
}

/* a thread object is either in a waiting queue awaiting CPU time, or is runnng and held in a physical CPU core struct.
if you remove a thread object from the queue and don't place it back in a queue or Core structure,
then the thread will be dropped, deallocated and destroyed. */
pub struct Thread
{
    container: ContainerID,
    priority: Priority,
    state: SupervisorState
}

impl Thread
{
    /* create a new supervisor-level CPU thread for a container
    => name = name of the container
        entry = pointer to thread's start address
        stack = stack pointer value to use, relative to allocated phys RAM
        priority = thread priority
        <= OK for success, or error code */
    pub fn create(name: ContainerID, entry: extern "C" fn () -> (), stack: PhysMemBase, priority: Priority) -> Result<(), Cause>
    {
        let phys_ram = match get_phys_ram(name.clone())
        {
            Some(r) => r,
            None => return Err(Cause::ContainerBadName)
        };

        let new_thread = Thread
        {
            container: name,
            priority: priority,
            state: supervisor_state_from(entry, phys_ram.base() + stack)
        };

        /* add thread to the global waiting list queue */
        scheduler::queue(new_thread);
        Ok(())
    }

    /* return reference to thread's physical CPU state */
    pub fn state_as_ref(&self) -> &SupervisorState
    {
        &self.state
    }
    
    /* return copy of thread container's name */
    pub fn container(&self) -> ContainerID
    {
        self.container.clone()
    }

    pub fn get_priority(&self) -> Priority { self.priority }
}
