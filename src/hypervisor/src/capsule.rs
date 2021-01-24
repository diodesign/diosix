/* diosix capsule management
 *
 * (c) Chris Williams, 2019-2021.
 *
 * See LICENSE for usage and copying.
 */

use core::sync::atomic::{AtomicUsize, Ordering};
use super::lock::Mutex;
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
    static ref CAPSULES: Mutex<HashMap<CapsuleID, Capsule>> = Mutex::new("capsule ID table", HashMap::new());

    /* set of capsules to restart */
    static ref TO_RESTART: Mutex<HashSet<CapsuleID>> = Mutex::new("capsule restart list", HashSet::new());
}

/* perform housekeeping duties on idle physical CPU cores */
macro_rules! capsulehousekeeper
{
    () => ($crate::capsule::restart_awaiting());
}

/* empty the waiting list of capsules to restart and recreate their vcores */
pub fn restart_awaiting()
{
    for cid in TO_RESTART.lock().drain()
    {
        if let Some(c) = CAPSULES.lock().get_mut(&cid)
        {
            /* capsule is ready to roll again, call this before injecting
            virtual cores into the scheduling queues */
            c.set_state_valid();

            /* TODO: if the capsule is corrupt, it'll crash again. support
            a hard reset if the capsule can't start */

            for (vid, params) in c.iter_init()
            {
                if let Err(_e) = add_vcore(cid, *vid, params.entry, params.dtb, params.prio)
                {
                    hvalert!("Failed to restart capsule {} vcore {}: {:?}", cid, vid, _e);
                }
            }
        }
    }
}

#[derive(Copy, Clone, PartialEq, Eq, Debug)]
pub enum CapsuleState
{
    Valid,      /* ok to run */
    Dying,      /* remove vcores and kill when there are none left */
    Restarting  /* remove vcores and recreate vcores with initial params */
}

/* record the initialization parameters for a virtual core
   so it can be recreated and restarted */
pub struct VcoreInit
{
    entry: Entry, 
    dtb: PhysMemBase,
    prio: Priority
}

struct Capsule
{
    state: CapsuleState,                     /* define whether this capsule is alive, dying or restarting */
    restart_on_crash: bool,                  /* true to auto-restart on unexpected death */
    vcores: HashSet<VirtualCoreID>,          /* set of virtual core IDs assigned to this capsule */
    init: HashMap<VirtualCoreID, VcoreInit>, /* map of vcore IDs to vcore initialization paramters */
    memory: Vec<Mapping>,                    /* map capsule supervisor virtual addresses to host physical addresses */
    allowed_services: HashSet<ServiceID>,    /* set of services this capsule is allowed to provide */
    debug_buffer: String                     /* buffer to hold debug output until it's flushed */
}

impl Capsule
{
    /* create a new empty capsule using the current capsule on this physical CPU core.
    => auto_restart_flag = tue to auto-restart on crash by the hypervisor
    <= capsule object, or error code */
    pub fn new(restart_on_crash: bool) -> Result<Capsule, Cause>
    {
        Ok(Capsule
        {
            state: CapsuleState::Valid,
            restart_on_crash,
            vcores: HashSet::new(),
            init: HashMap::new(),
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

    /* add a virtual core ID to the capsule */
    pub fn add_vcore(&mut self, id: VirtualCoreID)
    {
        self.vcores.insert(id);
    }

    /* add a virtual core's initialization parameters to the capsule */
    pub fn add_init(&mut self, vid: VirtualCoreID, entry: Entry, dtb: PhysMemBase, prio: Priority)
    {
        self.init.insert(vid, VcoreInit { entry, dtb, prio });
    }

    pub fn iter_init(&self) -> hashbrown::hash_map::Iter<'_, VirtualCoreID, VcoreInit>
    {
        self.init.iter()
    }

    /* remove a virtual core ID from the capsule's list */
    pub fn remove_vcore(&mut self, id: VirtualCoreID)
    {
        self.vcores.remove(&id);
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

    /* return this capsule's state */
    pub fn get_state(&self) -> CapsuleState { self.state }

    /* mark this capsule as dying. returns true if this is possible.
    only valid or dying capsules can die */
    pub fn set_state_dying(&mut self) -> bool
    {
        match self.state
        {
            CapsuleState::Dying => (),
            CapsuleState::Valid => self.state = CapsuleState::Dying,
            _ => return false
        }

        true
    }

    /* mark this capsule as restarting. returns true if this is possible.
    only valid or restarting capsules can restart */
    pub fn set_state_restarting(&mut self) -> bool
    {
        match self.state
        {
            CapsuleState::Restarting => (),
            CapsuleState::Valid => self.state = CapsuleState::Restarting,
            _ => return false
        }

        true
    }

    /* mark the capsule's state as valid */
    pub fn set_state_valid(&mut self) { self.state = CapsuleState::Valid; }
}

/* handle the destruction of a capsule */
impl Drop for Capsule
{
    fn drop(&mut self)
    {
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
                Err(_e) => hvalert!("Failed to deregister service during teardown of capsule {:p}: {:?}", &self, _e),
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
        Some(c) =>
        {
            /* register the vcore ID and stash its init params */
            c.add_vcore(vid);
            c.add_init(vid, entry, dtb, prio);
        },
        None => return Err(Cause::CapsuleBadID)
    };
    Ok(())
}

/* create a new blank capsule
   Once created, it needs to be given a supervisor image, at least.
   then it is ready to be scheduled by assigning it virtual CPU cores.
   => auto_crash_restart = true to be auto-restarted by hypervisor if the capsule crashes
   <= CapsuleID for this new capsule, or an error code */
pub fn create(auto_crash_restart: bool) -> Result<CapsuleID, Cause>
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
                capsules.insert(new_id, Capsule::new(auto_crash_restart)?);

                /* we're all done here */
                return Ok(new_id);
            },
            _ => () /* try again */
        };
    }
}

/* destroy the given virtualcore within the given capsule.
   when the capsule is out of vcores, destroy it.
   see destroy_current() for more details */
fn destroy(cid: CapsuleID, vid: VirtualCoreID) -> Result<(), Cause>
{
    /* make sure this capsule is dying */
    let mut lock = CAPSULES.lock();
    if let Some(victim) = CAPSULES.lock().get_mut(&cid)
    {
        match victim.set_state_dying()
        {
            true =>
            {
                /* remove this current vcore ID from the capsule's
                hash table. also mark the vcore as doomed, meaning
                it will be dropped when it's context switched out */
                victim.remove_vcore(vid);
                pcore::PhysicalCore::this().doom_vcore();

                /* are there any vcores remaining? */
                if victim.count_vcores() == 0
                {
                    /* if not then remove this capsule
                    from the hash table, which should
                    trigger the final teardown via drop */
                    lock.remove(&cid);
                }

                return Ok(());
            },
            false => return Err(Cause::CapsuleCantDie)
        }
    }
    else
    {
        Err(Cause::CapsuleBadID)
    }
}

/* mark the currently running capsule as dying,
   or continue to kill off the capsule. each vcore
   should call this when it realizes the capsule
   is dying so that the current vcore can be removed.
   it can be called multiple times per vcore.
   when there are no vcores left, its RAM
   and any other resources will be deallocated.
   when the vcore count drops to zero, it will drop.
   it's on the caller of destroy_capsule() to reschedule
   another vcore to run.
   <= Ok for success, or an error code
*/
pub fn destroy_current() -> Result<(), Cause>
{
    let (cid, vid) = match pcore::PhysicalCore::this().get_virtualcore_id()
    {
        Some(id) => (id.capsuleid, id.vcoreid),
        None =>
        {
            hvalert!("BUG: Can't find currently running capsule to destroy");
            return Err(Cause::CapsuleBadID);
        }
    };

    destroy(cid, vid)
}

/* remove the given virtual core from the capsule and mark it as restarting.
   see restart_current() for more details */
fn restart(cid: CapsuleID, vid: VirtualCoreID) -> Result<(), Cause>
{ 
    /* make sure this capsule is restarting */
    let mut lock = CAPSULES.lock();

    if let Some(victim) = lock.get_mut(&cid)
    {
        match victim.set_state_restarting()
        {
            true =>
            {
                /* remove this current vcore ID from the capsule's
                hash table. also mark the vcore as doomed, meaning
                it will be dropped when it's context switched out */
                victim.remove_vcore(vid);
                pcore::PhysicalCore::this().doom_vcore();

                /* are there any vcores remaining? */
                if victim.count_vcores() == 0
                {
                    /* no vcores left so add this capsule to the restart set */
                    TO_RESTART.lock().insert(cid);
                }

                return Ok(());
            },

            false => return Err(Cause::CapsuleCantRestart)
        }
    }
    else
    {
        Err(Cause::CapsuleBadID)
    }
}

/* recreate and restart the currently running capsule, if possible.
   it can be called multiple times per vcore. each vcore should call
   this within the capsule when it realizes the capsule is restarting.
   when all vcores have call this function, the capsule will restart proper.
   it's on the caller of restart_current() to reschedule another vcore to run.
   <= Ok for success, or an error code
*/
pub fn restart_current() -> Result<(), Cause>
{
    let (cid, vid) = match pcore::PhysicalCore::this().get_virtualcore_id()
    {
        Some(id) => (id.capsuleid, id.vcoreid),
        None =>
        {
            hvalert!("BUG: Can't find currently running capsule to restart");
            return Err(Cause::CapsuleBadID);
        }
    };

    restart(cid, vid)
}

/* return the state of the given capsule, identified by ID, or None for not found */
pub fn get_state(cid: CapsuleID) -> Option<CapsuleState>
{
    match CAPSULES.lock().entry(cid)
    {
        Occupied(capsule) => Some(capsule.get().state),
        Vacant(_) => None
    }
}

/* get the current capsule's state, or None if no running capsule */
pub fn get_current_state() -> Option<CapsuleState>
{
    if let Some(cid) = pcore::PhysicalCore::get_capsule_id()
    {
        return get_state(cid);
    }

    None
}

/* return currently running capsule's auto-restart-on-crash flag as
   Some(true) or Some(false) as appropriate, or None for no running capsule */
pub fn is_current_autorestart() -> Option<bool>
{
    let cid = match pcore::PhysicalCore::get_capsule_id()
    {
        Some(id) => id,
        None => return None
    };

    match CAPSULES.lock().entry(cid)
    {
        Occupied(capsule) => return Some(capsule.get().restart_on_crash),
        Vacant(_) => None
    }
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
                    if index == 0
                    {
                        r.grant_access();
                    }
                    else
                    {
                        hvalert!("BUG: Capsule {} has more than one physical RAM region", id);
                    }
                    index = index + 1;
                }
            }
            return true
        },
        _ => false
    }
}
