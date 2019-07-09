/* diosix container management
 *
 * (c) Chris Williams, 2019.
 *
 * See LICENSE for usage and copying.
 */

use platform::physmem::PhysMemSize;
use physmem::{self, Region, RegionUse::*};
use spin::Mutex;
use error::Cause;
use alloc::boxed::Box;
use hashmap_core::map::HashMap;
use hashmap_core::map::Entry::Occupied;
use alloc::string::String;
use cpu::CPUCount;

pub type ContainerID = String;

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
pub fn create_from_builtin(name: ContainerID, size: PhysMemSize, cpus: CPUCount) -> Result<(), Cause>
{
    let ram = physmem::alloc_region(size, ContainerRAM)?;  /* read-write general-purpose RAM */
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
fn create(name: ContainerID, ram: Region, code: Region, data: Region, cpus: CPUCount) -> Result<(), Cause>
{
    let new_container = Container::new(ram, code, data, cpus)?;

    klog!("Created {} container: CPUs {} RAM 0x{:x}-0x{:x} code 0x{:x}-0x{:x} data 0x{:x}-0x{:x}",
            name, cpus, ram.base(), ram.end(), code.base(), code.end(), data.base(), data.end());

    /* check to see if this container already exists */
    let mut containers = CONTAINERS.lock();
    match containers.entry(name.clone())
    {
        Occupied(_) => Err(Cause::ContainerAlreadyExists),
        _ =>
        {
            /* insert our new container */
            containers.insert(String::from(name), new_container);
            Ok(())
        }
    }
}

struct Container
{
    cpus: CPUCount, /* max number of CPU threads executing in this container */
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
    pub fn new(ram: Region, code: Region, data: Region, cpus: CPUCount) -> Result<Container, Cause>
    {
        Ok(Container
        {
            cpus: cpus,
            ram: ram,
            code: code,
            data: data
        })
    }

    /* describe the physical RAM region of this container */
    pub fn phys_ram(&self) -> Region { self.ram }

    /* enforce physical ram protections for this container on this CPU core,
    replacing any previous protections, leaving just this container as the only
    valid supervisor-level physical RAM areas */
    pub fn enforce(&self)
    {
        self.ram.protect();
        self.code.protect();
        self.data.protect();
    }
}

/* lookup the phys RAM region of a container from its name
   <= physical memory region, or None for no such container */
pub fn get_phys_ram(name: ContainerID) -> Option<Region>
{
    match CONTAINERS.lock().entry(name)
    {
        Occupied(c) =>  return Some(c.get().phys_ram()),
        _ => None
    }   
}

/* enforce hardware security restrictions for the given container,
preventing accesses outside of each region type. this replaces
any previous access resitractions, leaving just accessible regions
safe for this incoming container. return true for success, false for failure */
pub fn enforce(name: ContainerID) -> bool
{
    match CONTAINERS.lock().entry(name)
    {
        Occupied(c) => 
        {
            c.get().enforce();
            true
        },
        _ => false
    }
}
