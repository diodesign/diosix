/* diosix capsule management
 *
 * (c) Chris Williams, 2019-2020.
 *
 * See LICENSE for usage and copying.
 */

use spin::Mutex;
use hashbrown::hash_map::HashMap;
use hashbrown::hash_map::Entry::{Occupied, Vacant};
use hashbrown::hash_set::HashSet;
use alloc::vec::Vec;
use platform::cpu::Entry;
use platform::physmem::PhysMemBase;
use super::loader;
use super::error::Cause;
use super::physmem;
use super::virtmem::Mapping;
use super::vcore::{self, Priority, VirtualCoreID};
use super::service::ServiceID;
use super::service;
use super::hardware;
use super::pcore;

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

struct Capsule
{
    restart: bool,                          /* true to auto-restart on death */
    vcores: HashSet<VirtualCoreID>,         /* set of virtual core IDs assigned to this capsule */
    memory: Vec<Mapping>,                   /* map capsule supervisor virtual addresses to host physical addresses */
    allowed_services: HashSet<ServiceID>    /* set of services this capsule is allowed to provide */
}

impl Capsule
{
    /* create a new empty capsule using the current capsule on this physical CPU core.
    => auto_restart_flag = tue to auto-restart on death by the hypervisor (eg, for the boot capsule)
    <= capsule object, or error code */
    pub fn new(auto_restart_flag: bool) -> Result<Capsule, Cause>
    {
        Ok(Capsule
        {
            restart: auto_restart_flag,
            vcores: HashSet::new(),
            memory: Vec::new(),
            allowed_services: HashSet::new(),
        })
    }

    /* add a mapping to this capsule */
    pub fn set_memory_mapping(&mut self, to_add: Mapping)
    {
        self.memory.push(to_add);
    }

    /* get a copy of the capsule's memory mappings */
    pub fn get_memory_mappings(&self) -> Vec<Mapping> { self.memory.clone() }

    /* boot capsules are auto-restarted by the hypervisor */
    pub fn set_auto_restart(&mut self, flag: bool)
    {
        self.restart = flag;
    }

    /* returns true if this will auto-restart, or false if not */
    pub fn will_auto_restart(&self) -> bool
    {
        self.restart
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

/* handle the destruction of a capsule */
impl Drop for Capsule
{
    fn drop(&mut self)
    {
        hvdebug!("Tearing down capsule {:p}", &self);
        
        /* free up memory... */
        for mapping in self.memory.clone()
        {
            if let Some(r) = mapping.get_physical()
            {
                match physmem::dealloc_region(r)
                {
                    Err(e) => hvalert!("Error during capsule {:p} teardown: {:?}", &self, e),
                    Ok(_) => ()
                };
            }
        }

        /* ...and services held by this capsule */
        for sid in self.allowed_services.iter()
        {
            match service::deregister(*sid)
            {
                Err(e) => hvalert!("Failed to deregister service during teardown of capsule {:p}: {:?}", &self, e),
                Ok(()) => ()
            };
        }
    }
}

/* create the boot capsule, from which all other capsules spawn */
pub fn create_boot_capsule() -> Result<(), Cause>
{
    /* create an auto-restarting capsule */
    let capid = create(true)?;

    /* assign one virtual CPU core to the boot capsule */
    let cpus = 1;

    /* reserve 64MB of physical RAM for the capsule */
    let size = 64 * 1024 * 1024;
    let ram = physmem::alloc_region(size)?;

    /* create device tree blob for the virtual hardware available to the guest
    capsule and copy into the end of the region's physical RAM.
    a zero-length DTB indicates something went wrong */
    let guest_dtb = hardware::clone_dtb_for_capsule(cpus, 0, ram.base(), ram.size())?;
    if guest_dtb.len() == 0
    {
        return Err(Cause::BootDeviceTreeBad);
    }

    let guest_dtb_base = ram.fill_end(guest_dtb)?;

    /* map that physical memory into the capsule */
    let mut mapping = Mapping::new();
    mapping.set_physical(ram);
    mapping.identity_mapping()?;
    map_memory(capid, mapping)?;
    
    /* parse + copy the boot capsule's binary into its physical memory */
    let phys_binary_location = physmem::boot_supervisor();
    let entry = loader::load(ram, phys_binary_location)?;

    /* create virtual CPU cores for the capsule as required */
    for vcoreid in 0..cpus
    {
        create_and_add_vcore(capid, vcoreid, entry, guest_dtb_base, Priority::High)?;
    }
    Ok(())
}

/* create a virtual core and add it to the given capsule
   => cid = capsule ID
      vid = virtual core ID
      entry = starting address for execution of this virtual core
      dtb = physical address of the device tree blob describing
            the virtual hardware environment
      prio = priority to run this virtual core
   <= return Ok for success, or error code
*/
pub fn create_and_add_vcore(cid: CapsuleID, vid: VirtualCoreID, entry: Entry, dtb: PhysMemBase, prio: Priority) -> Result<(), Cause>
{
    vcore::VirtualCore::create(cid, vid, entry, dtb, prio)?;
    match CAPSULES.lock().get_mut(&cid)
    {
        Some(c) => c.add_vcore(vid),
        None => return Err(Cause::CapsuleBadID)
    };
    Ok(())
}

/* create a new blank capsule
   Once created, it needs to be given a supervisor image, at least.
   then it is ready to be scheduled by assigning it virtual CPU cores.
   => auto_restart = true to be auto-restarted by hypervisor
   <= CapsuleID for this new capsule, or an error code */
fn create(auto_restart: bool) -> Result<CapsuleID, Cause>
{
    let new_capsule = Capsule::new(auto_restart)?;

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
        drop(victim); // see above implementation of drop for Capsule
        Ok(())
    }
    else
    {
        Err(Cause::CapsuleBadID)
    }
}

/* destroy() the currently running capsule */
pub fn destroy_current() -> Result<(), Cause>
{
    if let Some(c) = pcore::PhysicalCore::get_capsule_id()
    {
        if let Err(e) = destroy(c)
        {
            hvalert!("BUG: Could not kill currently running capsule ID {} ({:?})", c, e);
        }

        return Ok(())
    }

    Err(Cause::CapsuleBadID)
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
        Occupied(c) => Some(c.get().check_service(sid)),
        Vacant(_) => None
    }
}

/* add a memory mapping to a capsule
   cid = ID of capsule to add the mapping to
   to_map = memory mapping object to add
   Ok for success, or an error code
*/
pub fn map_memory(cid: CapsuleID, to_map: Mapping) -> Result<(), Cause>
{
    if let Occupied(mut c) = CAPSULES.lock().entry(cid)
    {
        c.get_mut().set_memory_mapping(to_map);
        return Ok(());
    }
    else
    {
        return Err(Cause::CapsuleBadID);
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
    /* this is a filthy hardcode hack that I hate but it's needed for now */
    let mut index = 0;

    match CAPSULES.lock().entry(id)
    {
        Occupied(c) => 
        {
            for mapping in c.get().get_memory_mappings()
            {
                if let Some(r) = mapping.get_physical()
                {
                    if index > 0
                    {
                        panic!("TODO / FIXME: Capsules can't have more than one physical RAM region");
                    }

                    r.grant_access();
                    index = index + 1;
                }
            }
            return true
        },
        _ => false
    }
}
