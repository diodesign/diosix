/* diosix capsule management
 *
 * (c) Chris Williams, 2019-2021.
 *
 * See LICENSE for usage and copying.
 */

use core::sync::atomic::{AtomicUsize, Ordering};
use spin::Mutex;
use hashbrown::hash_map::HashMap;
use hashbrown::hash_map::Entry::{Occupied, Vacant};
use hashbrown::hash_set::HashSet;
use alloc::vec::Vec;
use alloc::string::String;
use platform::cpu::Entry;
use platform::physmem::PhysMemBase;
use super::error::Cause;
use super::physmem;
use super::virtmem::Mapping;
use super::vcore::{self, Priority, VirtualCoreID};
use super::service::ServiceID;
use super::service;
use super::pcore;
use super::manifest;

pub type CapsuleID = usize;

/* arbitrarily allow up to CAPSULES_MAX capsules in the system */
const CAPSULES_MAX: usize = 1000000;

/* needed to assign system-wide unique capsule ID numbers */
lazy_static!
{
    static ref CAPSULE_ID_NEXT: AtomicUsize = AtomicUsize::new(0);
}

/* maintain a shared table of capsules */
lazy_static!
{
    /* acquire CAPSULES lock before accessing any capsules */
    static ref CAPSULES: Mutex<HashMap<CapsuleID, Capsule>> = Mutex::new(HashMap::new());
}

/* define who or what is responsible for restarting this capsule */
#[derive(Debug)]
pub enum RestartMethod
{
    FromManifest(String),   /* reload from the included manifest fs image */
    FromSpawnService        /* tell the capsule spawning service to reload us */
}

struct Capsule
{
    restart_on_crash: bool,                 /* true to auto-restart on unexpected death */
    restart_method: RestartMethod,          /* how to restart this capsule */
    vcores: HashSet<VirtualCoreID>,         /* set of virtual core IDs assigned to this capsule */
    memory: Vec<Mapping>,                   /* map capsule supervisor virtual addresses to host physical addresses */
    allowed_services: HashSet<ServiceID>,   /* set of services this capsule is allowed to provide */
    debug_buffer: String                    /* buffer to hold debug output until it's flushed */
}

impl Capsule
{
    /* create a new empty capsule using the current capsule on this physical CPU core.
    => auto_restart_flag = tue to auto-restart on crash by the hypervisor
    <= capsule object, or error code */
    pub fn new(restart_on_crash: bool, restart_method: RestartMethod) -> Result<Capsule, Cause>
    {
        Ok(Capsule
        {
            restart_on_crash,
            restart_method,
            vcores: HashSet::new(),
            memory: Vec::new(),
            allowed_services: HashSet::new(),
            debug_buffer: String::new()
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
    pub fn set_auto_crash_restart(&mut self, flag: bool)
    {
        self.restart_on_crash = flag;
    }

    /* returns true if this will auto-restart, or false if not */
    pub fn will_auto_crash_restart(&self) -> bool
    {
        self.restart_on_crash
    }

    /* returns restart method */
    pub fn get_restart_method(&self) -> &RestartMethod { &self.restart_method }

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

/* create a virtual core and add it to the given capsule
   => cid = capsule ID
      vid = virtual core ID
      entry = starting address for execution of this virtual core
      dtb = physical address of the device tree blob describing
            the virtual hardware environment
      prio = priority to run this virtual core
   <= return Ok for success, or error code
*/
pub fn add_vcore(cid: CapsuleID, vid: VirtualCoreID, entry: Entry, dtb: PhysMemBase, prio: Priority) -> Result<(), Cause>
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
   => auto_crash_restart = true to be auto-restarted by hypervisor if the capsule crashes
   <= CapsuleID for this new capsule, or an error code */
pub fn create(auto_crash_restart: bool, restart_method: RestartMethod) -> Result<CapsuleID, Cause>
{
    /* repeatedly try to generate an available ID */
    loop
    {
        /* bail out if we're at the limit */
        let mut capsules = CAPSULES.lock();
        if capsules.len() > CAPSULES_MAX
        {
            return Err(Cause::CapsuleIDExhaustion);
        }

        /* get next ID and check to see if this capsule already exists */
        let new_id = CAPSULE_ID_NEXT.fetch_add(1, Ordering::SeqCst);
        match capsules.entry(new_id)
        {
            Vacant(_) =>
            {
                /* insert our new capsule */
                capsules.insert(new_id, Capsule::new(auto_crash_restart, restart_method)?);

                /* we're all done here */
                return Ok(new_id);
            },
            _ => () /* try again */
        };
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

/* mark a capsule as not only dying, but also recreate it.
   => cid = ID of capsule to restart
   <= Ok for success, or an error code
*/
pub fn restart(cid: CapsuleID) -> Result<(), Cause>
{
    let mut lock = CAPSULES.lock();
    if let Some(victim) = lock.remove(&cid)
    {
        match victim.get_restart_method()
        {
            RestartMethod::FromManifest(s) => match manifest::get_named_asset(&s.as_str())
            {
                Ok(a) =>
                {
                    drop(victim);
                    drop(lock);
                    manifest::load_asset(a)?;
                },
                Err(e) => return Err(e)
            },
            method => hvdebug!("Cannot restart capsule ID {} with method {:?}", cid, method)
        }
    }
    else
    {
        return Err(Cause::CapsuleBadID)
    }

    return Ok(());
}

/* destroy the currently running capsule */
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

/* restart the currently running capsule */
pub fn restart_current() -> Result<(), Cause>
{
    if let Some(c) = pcore::PhysicalCore::get_capsule_id()
    {
        if let Err(e) = restart(c)
        {
            hvalert!("BUG: Could not restart currently running capsule ID {} ({:?})", c, e);
        }

        return Ok(())
    }

    Err(Cause::CapsuleBadID)
}

/* buffer a character from the guest kernel, and flush output if a newline */
pub fn debug_write(cid: CapsuleID, character: char) -> Result<(), Cause>
{
    match CAPSULES.lock().entry(cid)
    {
        Occupied(mut capsule) =>
        {
            let c = capsule.get_mut();

            if character != '\n'
            {
                /* buffer the character if we're not at a newline */
                c.debug_buffer.push(character);
            }
            else
            {
                /* flush the buffer and reinitialize it */
                hvdebug!("Capsule {}: {}", cid, c.debug_buffer);
                c.debug_buffer = String::new();
            }
            Ok(())
        },
        Vacant(_) => Err(Cause::CapsuleBadID)
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
