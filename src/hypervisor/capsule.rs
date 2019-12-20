/* diosix capsule management
 *
 * (c) Chris Williams, 2019.
 *
 * See LICENSE for usage and copying.
 */

use spin::Mutex;
use hashbrown::hash_map::HashMap;
use hashbrown::hash_map::Entry::{Occupied, Vacant};
use hashbrown::hash_set::HashSet;
use platform::physmem::PhysMemSize;
use platform::cpu::Entry;
use super::loader;
use super::error::Cause;
use super::physmem::{self, Region};
use super::vcore::{self, Priority, VirtualCoreID};
use super::service::ServiceID;
use super::pcore::PhysicalCore;
use super::service;
use super::message;

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

/* create the boot capsule, from which all other capsules spawn */
pub fn create_boot_capsule() -> Result<(), Cause>
{
    /* create a boot capsule with 128MB of RAM and one virtual CPU core */
    let size = 128 * 1024 * 1024;
    let cpus = 1;

    let ram = physmem::alloc_region(size)?;
    let capid = create(ram, true)?;

    let supervisor = physmem::boot_supervisor();
    let entry = loader::load(ram, supervisor)?;

    /* create virtual CPU cores for the capsule as required */
    for vcoreid in 0..cpus
    {
        create_and_add_vcore(capid, vcoreid, entry, Priority::High)?;
    }
    Ok(())
}

/* create a virtual core and add it to the given capsule
   => cid = capsule ID
      vid = virtual core ID
      entry = starting address for execution of this virtual core
      prio = priority to run this virtual core
   <= return Ok for success, or error code
*/
pub fn create_and_add_vcore(cid: CapsuleID, vid: VirtualCoreID, entry: Entry, prio: Priority) -> Result<(), Cause>
{
    vcore::VirtualCore::create(cid, vid, entry, prio)?;
    match CAPSULES.lock().get_mut(&cid)
    {
        Some(c) => c.add_vcore(vid),
        None => return Err(Cause::CapsuleBadID)
    };
    Ok(())
}

/* create a new blank capsule
   Once created, it needs to be given a supervisor image, at least. then it is ready to be scheduled
   by assigning it virtual CPU cores.
   => ram = region of physical RAM reserved for this capsule
      is_boot = true for boot capsule (and thus auto-restarted by hypervisor)
   <= CapsuleID for this new capsule, or an error code */
fn create(ram: Region, is_boot: bool) -> Result<CapsuleID, Cause>
{
    let new_capsule = Capsule::new(ram, is_boot)?;

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
            Vacant(_) =>
            {
                /* insert our new capsule */
                capsules.insert(new_id, new_capsule);
                hvdebug!("Created capsule ID {}, physical RAM base 0x{:x}, size {} MiB", new_id, ram.base(), ram.size() / 1024 / 1024);

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

/* mark a capsule as dying, meaning its virtual cores will be
   gradually removed and when there are none left, its RAM
   and any other resources will be deallocated.
   => cid = ID of capsule to kill
   <= Ok for success, or an error code
*/
pub fn destroy(cid: CapsuleID) -> Result<(), Cause>
{
    if let Some(victim) = CAPSULES.lock().remove(&cid)
    {
        drop(victim);
        Ok(())
    }
    else
    {
        Err(Cause::CapsuleBadID)
    }
}

struct Capsule
{
    boot: bool,                             /* true if boot capsule, false otherwise */
    vcores: HashSet<VirtualCoreID>,         /* set of virtual core IDs assigned to this capsule */
    ram: Region,                            /* general purpose RAM area */
    allowed_services: HashSet<ServiceID>    /* set of services this capsule is allowed to provide */
}

/* handle the destruction of a capsule */
impl Drop for Capsule
{
    fn drop(&mut self)
    {
        hvdebug!("Tearing down capsule");
        
        /* free up memory and services held by this capsule */
        physmem::dealloc_region(self.ram);
        for sid in self.allowed_services.iter()
        {
            service::deregister(*sid);
        }
    }
}

impl Capsule
{
    /* create a new capsule using the current capsule on this physical CPU core
    as the parent.
    => ram = region of physical memory the capsule can use for general purpose RAM
       is_boot = true for boot capsule (auto-restart by hypervisor)
    <= capsule object, or error code */
    pub fn new(ram: Region, is_boot: bool) -> Result<Capsule, Cause>
    {
        Ok(Capsule
        {
            boot: is_boot,
            vcores: HashSet::new(),
            ram: ram,
            allowed_services: HashSet::new(),
        })
    }

    /* describe the physical RAM region of this capsule */
    pub fn phys_ram(&self) -> Region { self.ram }

    /* set whether this is a boot capsule or not.
    boot capsules are auto-restarted by the hypervisor */
    pub fn set_boot(&mut self, flag: bool)
    {
        self.boot = flag;
    }

    /* returns true if a boot capsule or false if not */
    pub fn is_boot(&self) -> bool
    {
        self.boot
    }

    /* add a virtual core ID to the capsule */
    pub fn add_vcore(&mut self, id: VirtualCoreID)
    {
        self.vcores.insert(id);
    }

    /* remove a virtual core ID from the capsule. returns true if that
       ID was present in the registered list */
    pub fn remove_vcore(&mut self, id: VirtualCoreID) -> bool
    {
        self.vcores.remove(&id)
    }

    /* return number of registered virtual cores */
    pub fn count_vcores(&self) -> usize
    {
        self.vcores.len()
    }

    /* allow capsule to register service sid */
    pub fn allow_service(&mut self, sid: ServiceID)
    {
        self.allowed_services.insert(sid);
    }

    /* check whether this capsule is allowed to register the given service
        <= true if allowed, false if not */
    pub fn check_service(&self, sid: ServiceID) -> bool
    {
        self.allowed_services.contains(&sid)
    }
}

/* allow a given capsule to offer a given service. if the capsule was already allowed the
   service then this returns without error.
    => cid = capsule ID
       sid = service ID
    <= Ok for success, or an error code */
pub fn allow_service(cid: CapsuleID, sid: ServiceID) -> Result<(), Cause>
{
    match CAPSULES.lock().entry(cid)
    {
        Occupied(mut c) =>
        {
            c.get_mut().allowed_services.insert(sid);
            Ok(())
        },
        Vacant(_) => Err(Cause::CapsuleBadID)
    }
}

/* check whether a capsule is allowed to run the given service
    => cid = capsule ID to check
       sid = service ID to check
    <= Some true if the capsule exists and is allowed, or Some false
        if the capsule exists and is not allowed, or None if
        the capsule doesn't exist */
pub fn is_service_allowed(cid: CapsuleID, sid: ServiceID) -> Option<bool>
{
    match CAPSULES.lock().entry(cid)
    {
        Occupied(c) => return Some(c.get().check_service(sid)),
        Vacant(_) => None
    }
}

/* lookup the phys RAM region of a capsule from its ID
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
