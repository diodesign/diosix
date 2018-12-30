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
use alloc::string::String;

pub type EnvironmentName = String;

/* maintain a shared linked list of supervisor environments and ID counter */
lazy_static!
{
    /* acquire ENVIRONMENTS lock before accessing any environments */
    static ref ENVIRONMENTS: Mutex<Box<LinkedList<Environment>>> = Mutex::new(box LinkedList::new());
}

/* create a new supervisor environment using the builtin supervisor kernel
   => name = text string identifying this environment
      size = minimum amount of RAM, in bytes, for this environment
      cpus = max number of virtual CPU threads that can be used
   <= OK with environment reference for success or an error code */
pub fn create_from_builtin(name: &str, size: usize, cpus: usize) -> Result<(), Cause>
{
    let ram = physmem::alloc_region(size, ReadWrite)?;  /* read-write general-purpose RAM */
    let code = physmem::builtin_supervisor_code();      /* read-execute-only (.sshared section) */
    let data = physmem::builtin_supervisor_data();      /* read-write (.sdata section) */
    Ok(create(name, ram, code, data, cpus)?)
}

/* create a new supervisor environment
   Once created, it is ready to be scheduled.
   => name = text identifier string for this environment
      ram = region of physical RAM reserved for this environment
      code = physical memory region holding supervisor's code
      data = physical memory region holding supervisor's static data
      cpus = maximum number of virtual CPU threads running through environment
   <= OK for success or an error code */
fn create(name: &str, ram: Region, code: Region, data: Region, cpus: usize) -> Result<(), Cause>
{
    let new_env = Environment::new(name, ram, code, data, cpus)?;

    klog!("Created {} supervisor environment: CPUs {} RAM 0x{:x}-0x{:x} code 0x{:x}-0x{:x} data 0x{:x}-0x{:x}",
            name, cpus, ram.base, ram.end, code.base, code.end, data.base, data.end);

    ENVIRONMENTS.lock().push_front(new_env);
    Ok(())
}

/* describe a supervisor environment */
struct Environment
{
    name: EnvironmentName,
    cpus: usize, /* max number of CPU threads executing in this environment */
    ram: Region, /* general purpose RAM area */
    code: Region, /* supervisor kernel read-execute-only area */
    data: Region /* supervisor kernel static data area */
}

impl Environment
{
    /* create a new supervisor kernel environment
    => name = name of this environment, used as a future identifier
       ram = region of physical memory the environment can for general purpose RAM
       code = region of physical memory holding the supervisor's executable code
       data = region of physical memory holding the supervisor's static data
       cpus = maximum number of virtual CPU threads this environment can request
    <= environment object, or error code */
    pub fn new(name: &str, ram: Region, code: Region, data: Region, cpus: usize) -> Result<Environment, Cause>
    {
        Ok(Environment
        {
            name: EnvironmentName::from(name),
            cpus: cpus,
            ram: ram,
            code: code,
            data: data
        })
    }
}
