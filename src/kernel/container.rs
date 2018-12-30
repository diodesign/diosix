/* diosix container management
 *
 * (c) Chris Williams, 2018.
 *
 * See LICENSE for usage and copying.
 */

use physmem::{self, Region, Permissions::*};
use spin::Mutex;
use error::Cause;
use alloc::boxed::Box;
use hashmap_core::map::HashMap;
use hashmap_core::map::Entry::Occupied;
use alloc::string::String;

pub type ContainerName = String;

/* maintain a shared table of containers */
lazy_static!
{
    /* acquire CONTAINERS lock before accessing any containers */
    static ref CONTAINERS: Mutex<Box<HashMap<String, Container>>> = Mutex::new(box HashMap::new());
}

/* create a new container using the builtin supervisor kernel
   => name = text string identifying this container
      size = minimum amount of RAM, in bytes, for this container
      cpus = max number of virtual CPU threads that can be used
   <= OK for success or an error code */
pub fn create_from_builtin(name: &str, size: usize, cpus: usize) -> Result<(), Cause>
{
    let ram = physmem::alloc_region(size, ReadWrite)?;  /* read-write general-purpose RAM */
    let code = physmem::builtin_supervisor_code();      /* read-execute-only (.sshared section) */
    let data = physmem::builtin_supervisor_data();      /* read-write (.sdata section) */
    Ok(create(name, ram, code, data, cpus)?)
}

/* create a new container
   Once created, it is ready to be scheduled.
   => name = text identifier string for this container
      ram = region of physical RAM reserved for this container
      code = physical memory region holding supervisor's code
      data = physical memory region holding supervisor's static data
      cpus = maximum number of virtual CPU threads running through container
   <= OK for success or an error code */
fn create(name: &str, ram: Region, code: Region, data: Region, cpus: usize) -> Result<(), Cause>
{
    let new_container = Container::new(ram, code, data, cpus)?;

    klog!("Created {} container: CPUs {} RAM 0x{:x}-0x{:x} code 0x{:x}-0x{:x} data 0x{:x}-0x{:x}",
            name, cpus, ram.base, ram.end, code.base, code.end, data.base, data.end);

    let name_string = String::from(name);
    let mut table = CONTAINERS.lock();

    /* check to see if this container already exists */
    match table.entry(name_string)
    {
        Occupied(_) => Err(Cause::ContainerAlreadyExists),
        _ =>
        {
            /* insert our new container */
            table.insert(String::from(name), new_container);
            Ok(())
        }
    }
}

struct Container
{
    cpus: usize, /* max number of CPU threads executing in this container */
    ram: Region, /* general purpose RAM area */
    code: Region, /* supervisor kernel read-execute-only area */
    data: Region /* supervisor kernel static data area */
}

impl Container
{
    /* create a new container
    => ram = region of physical memory the container can for general purpose RAM
       code = region of physical memory holding the supervisor's executable code
       data = region of physical memory holding the supervisor's static data
       cpus = maximum number of virtual CPU threads this container can request
    <= container object, or error code */
    pub fn new(ram: Region, code: Region, data: Region, cpus: usize) -> Result<Container, Cause>
    {
        Ok(Container
        {
            cpus: cpus,
            ram: ram,
            code: code,
            data: data
        })
    }
}
