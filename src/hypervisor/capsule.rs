/* diosix capsule management
 *
 * (c) Chris Williams, 2019.
 *
 * See LICENSE for usage and copying.
 */

use platform::physmem::PhysMemSize;
use super::physmem::{self, Region};
use super::vcore::{self, Priority};
use spin::Mutex;
use super::error::Cause;
use hashbrown::hash_map::HashMap;
use hashbrown::hash_map::Entry::Occupied;
use super::loader;

pub type CapsuleID = usize;

/* needed to assign system-wide unique capsule ID numbers */
lazy_static!
{
    static ref CAPSULE_ID_NEXT: Mutex<CapsuleID> = Mutex::new(0);
}

/* maintain a shared table of capsules */
lazy_static!
{
    /* acquire CAPSULES lock before accessing any capsules */
    static ref CAPSULES: Mutex<HashMap<CapsuleID, Capsule>> = Mutex::new(HashMap::new());
}

/* create a new capsule for the boot supervisor
   => size = minimum amount of RAM, in bytes, for this capsule
      cpus = number of virtual CPU cores to allow
   <= OK for success or an error code */
pub fn create_boot_capsule(size: PhysMemSize, cpus: usize) -> Result<(), Cause>
{
    let ram = physmem::alloc_region(size)?;
    let capsule = create(ram)?;

    let supervisor = physmem::boot_supervisor();
    let entry = loader::load(ram, supervisor)?;

    /* create virtual CPU cores for the capsule as required */
    for vcore in 0..cpus
    {
        vcore::VirtualCore::create(capsule, vcore, entry, Priority::High)?;
    }
    Ok(())
}

/* create a new blank capsule
   Once created, it needs to be given a supervisor image, at least. then it is ready to be scheduled
   by assigning it virtual CPU cores.
   => ram = region of physical RAM reserved for this capsule
   <= CapsuleID for this new capsule, or an error code */
fn create(ram: Region) -> Result<CapsuleID, Cause>
{
    let new_capsule = Capsule::new(ram)?;

    /* assign a new ID (in the unlikely event the given ID is already in-use, try again) */
    let mut overflowed_already = false;
    loop
    {
        let mut id = CAPSULE_ID_NEXT.lock();
        let (new_id, overflow) = id.overflowing_add(1);
        *id = new_id;

        /* check to see if this capsule already exists */
        let mut capsules = CAPSULES.lock();
        match capsules.entry(new_id)
        {
            hashbrown::hash_map::Entry::Vacant(_) =>
            {
                /* insert our new capsule */
                capsules.insert(new_id, new_capsule);
                hvlog!("Created capsule: ID {}, physical RAM base 0x{:x}, size {} MiB", new_id, ram.base(), ram.size() / 1024 / 1024);

                /* we're all done here */
                return Ok(new_id);
            },
            _ => () /* try again */
        };

        /* make sure we don't loop around forever hunting for a valid ID */
        if overflow == true
        {
            /* has this overflow happened before? */
            if overflowed_already == true
            {
                /* not the first time we overflowed, so give up */
                return Err(Cause::CapsuleIDExhaustion);
            }

            overflowed_already = true;
        }
    }
}

struct Capsule
{
    ram: Region, /* general purpose RAM area */
}

impl Capsule
{
    /* create a new capsule
    => ram = region of physical memory the capsule can for general purpose RAM
    <= capsule object, or error code */
    pub fn new(ram: Region) -> Result<Capsule, Cause>
    {
        Ok(Capsule
        {
            ram: ram
        })
    }

    /* describe the physical RAM region of this capsule */
    pub fn phys_ram(&self) -> Region { self.ram }
}

/* lookup the phys RAM region of a capsule from its name
   <= physical memory region, or None for no such capsule */
pub fn get_phys_ram(id: CapsuleID) -> Option<Region>
{
    match CAPSULES.lock().entry(id)
    {
        Occupied(c) =>  return Some(c.get().phys_ram()),
        _ => None
    }   
}

/* enforce hardware security restrictions for the given capsule.
   supervisor-level code will only be able to access the physical
   RAM covered by that assigned to the given capsule. call this
   when switching to a capsule, so that the previous enforcement is
   replaced by enforcement of this capsule. 
   => id = capsule to enforce
   <= true for success, or fail for failure
*/
pub fn enforce(id: CapsuleID) -> bool
{
    match CAPSULES.lock().entry(id)
    {
        Occupied(c) => 
        {
            c.get().phys_ram().grant_access();
            return true
        },
        _ => false
    }
}
