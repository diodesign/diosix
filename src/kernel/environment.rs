/* diosix supervisor environment management
 *
 * (c) Chris Williams, 2018.
 *
 * See LICENSE for usage and copying.
 */

use physmem;
use physmem::PhysRegion;
use lock::{Mutex, Spinlock};
use error::Cause;
use alloc::boxed::Box;
use alloc::collections::linked_list::LinkedList;

/* maintain a linked list of supervisor environments.
acquire ENVIRONMENTS_LOCK before accessing */
static mut ENVIRONMENTS_LOCK: Spinlock = kspinlock!();
static mut ENVIRONMENTS: Option<Box<LinkedList<Environment>>> = None;

/* create a new supervisor environment
   This uses the built-in supervisor. Once created, it ready to be scheduled.
   => size = minimum amount of physical RAM to be allocated for this environment
   <= OK for success or an error code */
pub fn create(size: usize) -> Result<(), Cause>
{
    let new_env = Environment::new(size)?;
    unsafe
    {
        ENVIRONMENTS_LOCK.aquire();

        /* if the list doesn't exist then initialize it */
        if ENVIRONMENTS.is_none() == true
        {
            ENVIRONMENTS = Some(box LinkedList::new());
        }

        let list = ENVIRONMENTS.as_mut().unwrap();
        list.push_front(new_env);

        ENVIRONMENTS_LOCK.release();
    }
    Ok(())
}

/* describe a supervisor kernel's environment */
struct EnvironmentData
{
    ram: PhysRegion, /* general purpose RAM area */
    code: PhysRegion, /* supervisor kernel read-execute-only area */
    data: PhysRegion /* supervisor kernel static data area */
}

struct Environment
{
    lock: Mutex<EnvironmentData>
}

impl Environment
{
    /* create a new supervisor kernel environment
    => size = minimum amount of physical RAM to be allocated for this environment
    <= environment object, or error code */
    pub fn new(size: usize) -> Result<Environment, Cause>
    {
        /* get a chunk of physical ram reserved for this environment */
        let ram = physmem::alloc(size)?;

        /* find the supervisor's executable code and data areas */
        let (code, data) = (physmem::builtin_supervisor_code(), physmem::builtin_supervisor_data());
        Ok(Environment
        {
            lock: Mutex::new(EnvironmentData
            {
                ram: ram,
                code: code,
                data: data
            })
        })
    }
}
