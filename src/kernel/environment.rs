/* diosix supervisor environment management
 *
 * (c) Chris Williams, 2018.
 *
 * See LICENSE for usage and copying.
 */

use physmem::{self, Region, Permissions::*};
use spin::Mutex;
use error::Cause;
use alloc::boxed::Box;
use alloc::collections::linked_list::LinkedList;

/* maintain a shared linked list of supervisor environments and ID counter */
lazy_static!
{
    /* acquire ENVIRONMENTS lock before accessing any environments */
    static ref ENVIRONMENTS: Mutex<Box<LinkedList<Environment>>> = Mutex::new(box LinkedList::new());
    static ref ENVIRONMENT_ID: Mutex<Box<EnvironmentID>> = Mutex::new(box 0);
}

pub type EnvironmentID = usize;

/* create a new supervisor environment using the builtin supervisor kernel
   => size = minimum amount of RAM, in bytes, for this environment
   <= OK for success or an error code */
pub fn create_from_builtin(size: usize, cpus: usize) -> Result<EnvironmentID, Cause>
{
    let ram = physmem::alloc_region(size, ReadWrite)?;  /* read-write general-purpose RAM */
    let code = physmem::builtin_supervisor_code();      /* read-execute-only (.sshared section) */
    let data = physmem::builtin_supervisor_data();      /* read-write (.sdata section) */
    Ok(create(ram, code, data, cpus)?)
}

/* create a new supervisor environment
   Once created, it is ready to be scheduled.
   => ram = region of physical RAM reserved for this environment
      code = physical memory region holding supervisor's code
      data = physical memory region holding supervisor's static data
      cpus = maximum number of CPU threads running through environment
   <= OK with environment's ID number, or an error code */
fn create(ram: Region, code: Region, data: Region, cpus: usize) -> Result<EnvironmentID, Cause>
{
    let new_env = Environment::new(ram, code, data, cpus)?;
    let id = new_env.get_id();

    let mut list = ENVIRONMENTS.lock();
    list.push_front(new_env);

    klog!("Created supervisor environment {}: CPUs {} RAM 0x{:x}-0x{:x} code 0x{:x}-0x{:x} data 0x{:x}-0x{:x}",
            id, cpus, ram.base, ram.end, code.base, code.end, data.base, data.end);

    Ok(id)
}

/* describe a supervisor environment */
struct Environment
{
    id: EnvironmentID, /* ID number of this environment */
    cpus: usize, /* max number of CPU threads executing in this environment */
    ram: Region, /* general purpose RAM area */
    code: Region, /* supervisor kernel read-execute-only area */
    data: Region /* supervisor kernel static data area */
}

impl Environment
{
    /* create a new supervisor kernel environment
    => size = minimum amount of physical RAM to be allocated for this environment
    <= environment object, or error code */
    pub fn new(ram: Region, code: Region, data: Region, cpus: usize) -> Result<Environment, Cause>
    {
        /* take current ID number and incrememnt ID for next environment */
        let mut current_id = ENVIRONMENT_ID.lock();
        let id = **current_id;
        **current_id = **current_id + 1; /* TODO: deal with this potentially wrapping around */

        Ok(Environment
        {
            id: id,
            cpus: cpus,
            ram: ram,
            code: code,
            data: data
        })
    }

    /* return ID number of this environment */
    pub fn get_id(&self) -> usize { self.id }
}
