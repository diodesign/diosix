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
use super::service::{self, ServiceType, SelectService};
use super::pcore;
use super::hardware;

pub type CapsuleID = usize;

/* arbitrarily allow up to CAPSULES_MAX capsules in a system at any one time */
const CAPSULES_MAX: usize = 1000000;

/* needed to assign system-wide unique capsule ID numbers */
lazy_static!
{
    static ref CAPSULE_ID_NEXT: AtomicUsize = AtomicUsize::new(0);
}

/* maintain a shared table of capsules and linked data */
lazy_static!
{
    /* acquire CAPSULES lock before accessing any capsules */
    static ref CAPSULES: Mutex<HashMap<CapsuleID, Capsule>> = Mutex::new("capsule ID table", HashMap::new());

    /* set of capsules to restart */
    static ref TO_RESTART: Mutex<HashSet<CapsuleID>> = Mutex::new("capsule restart list", HashSet::new());

    /* maintain collective input and output system console buffers for capsules.
       the console system service capsule (ServiceConsole) will read from
       STDOUT to display capsules' text, and will write to STDIN to inject characters into capsules */
    static ref STDIN: Mutex<HashMap<CapsuleID, Vec<char>>> = Mutex::new("capsule STDIN table", HashMap::new());
    static ref STDOUT: Mutex<HashMap<CapsuleID, Vec<char>>> = Mutex::new("capsule STDOUT table", HashMap::new());
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

#[derive(PartialEq, Eq, Hash, Debug)]
enum CapsuleProperty
{
    AutoCrashRestart,   /* restart this capsule when it crashes */
    ServiceConsole,     /* allow capsule to handle abstracted system console */
    ConsoleWrite,       /* allow capsule to write out to the console */
    ConsoleRead         /* allow capsule to read the console */
}

impl CapsuleProperty
{
    /* return true if this property allows the capsule to run the given service type */
    pub fn match_service(&self, stype: ServiceType) -> bool
    {
        match (self, stype)
        {
            (CapsuleProperty::ServiceConsole, ServiceType::ConsoleInterface) => true,
            (_, _) => false
        }
    }

    /* convert a property string into an CapsuleProperty, or None if not possible */
    pub fn string_to_property(property: &String) -> Option<CapsuleProperty>
    {
        /* restart the capsule if it crashes (as opposed to exits cleanly) */
        if property.eq_ignore_ascii_case("auto_crash_restart")
        {
            return Some(CapsuleProperty::AutoCrashRestart);
        }

        /* console related properties */
        if property.eq_ignore_ascii_case("service_console")
        {
            return Some(CapsuleProperty::ServiceConsole);
        }
        if property.eq_ignore_ascii_case("console_write")
        {
            return Some(CapsuleProperty::ConsoleWrite);
        }
        if property.eq_ignore_ascii_case("console_read")
        {
            return Some(CapsuleProperty::ConsoleRead);
        }

        None
    }
}

struct Capsule
{
    state: CapsuleState,                     /* define whether this capsule is alive, dying or restarting */
    properties: HashSet<CapsuleProperty>,    /* set of properties and rights assigned to this capsule */
    vcores: HashSet<VirtualCoreID>,          /* set of virtual core IDs assigned to this capsule */
    init: HashMap<VirtualCoreID, VcoreInit>, /* map of vcore IDs to vcore initialization paramters */
    memory: Vec<Mapping>,                    /* map capsule supervisor virtual addresses to host physical addresses */
}

impl Capsule
{
    /* create a new empty capsule using the current capsule on this physical CPU core.
    => properties = properties granted to this capsules, or None
    <= capsule object, or error code */
    pub fn new(property_strings: Option<Vec<String>>) -> Result<Capsule, Cause>
    {
        /* turn a possible list of property strings into list of official properties */
        let mut properties = HashSet::new();
        if let Some(property_strings) = property_strings
        {
            for string in property_strings
            {
                if let Some(prop) = CapsuleProperty::string_to_property(&string)
                {
                    properties.insert(prop);
                }
            }
        }

        Ok(Capsule
        {
            state: CapsuleState::Valid,
            properties,
            vcores: HashSet::new(),
            init: HashMap::new(),
            memory: Vec::new()
        })
    }

    /* add a mapping to this capsule */
    pub fn set_memory_mapping(&mut self, to_add: Mapping)
    {
        self.memory.push(to_add);
    }

    /* get a copy of the capsule's memory mappings */
    pub fn get_memory_mappings(&self) -> Vec<Mapping> { self.memory.clone() }

    /* returns true if property is present for this capsule, or false if not */
    pub fn has_property(&self, property: CapsuleProperty) -> bool
    {
        self.properties.contains(&property)
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

    /* check whether this capsule is allowed to register the given service
        <= true if allowed, false if not */
    pub fn can_offer_service(&self, stype: ServiceType) -> bool
    {
        for property in &self.properties
        {
            if property.match_service(stype) == true
            {
                return true;
            }
        }

        false
    }

    /* return this capsule's state */
    pub fn get_state(&self) -> &CapsuleState { &self.state }

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
   => properties = array of properties to apply to this capsule, or None
   <= CapsuleID for this new capsule, or an error code */
pub fn create(properties: Option<Vec<String>>) -> Result<CapsuleID, Cause>
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
                capsules.insert(new_id, Capsule::new(properties)?);

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
                    /* if not then deregister any and all services
                       belonging to this capsule */
                    service::deregister(SelectService::AllServices, cid)?;
                    
                    /* next, remove this capsule
                    from the global hash table, which should
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

/* Return Some(true) if capsule currently running on this physical core
   is allowed to restart if it's crashed. Some(false) if not, or None
   if this physical core isn't running a capsule */
pub fn is_current_autorestart() -> Option<bool>
{
    let cid = match pcore::PhysicalCore::get_capsule_id()
    {
        Some(id) => id,
        None => return None
    };

    match CAPSULES.lock().entry(cid)
    {
        Occupied(capsule) => return Some(capsule.get().has_property(CapsuleProperty::AutoCrashRestart)),
        Vacant(_) => None
    }
}

/* check whether a capsule is allowed to run the given service
    => cid = capsule ID to check
       stype = service  to check
    <= Some true if the capsule exists and is allowed, or Some false
        if the capsule exists and is not allowed, or None if
        the capsule doesn't exist */
pub fn is_service_allowed(cid: CapsuleID, stype: ServiceType) -> Result<bool, Cause>
{
    match CAPSULES.lock().entry(cid)
    {
        Occupied(c) => Ok(c.get().can_offer_service(stype)),
        Vacant(_) => Err(Cause::CapsuleBadID)
    }
}

/* write a character to the user as the given capsule.
   this will either be buffered and accessed later by the user interface
   to display to the user, or this is the user interface capsule
   and we'll pass its output onto the hardware */
pub fn putc(cid: CapsuleID, character: char) -> Result<(), Cause>
{
    /* find the capsule we're going to write into */
    match CAPSULES.lock().get_mut(&cid)
    {
        Some(capsule) =>
        {
            /* if this capsule can write straight to the hardware, then use that */
            if (*capsule).has_property(CapsuleProperty::ConsoleWrite)
            {
                hardware::write_debug_string(format!("{}", character).as_str());
            }
            else
            {
                /* either add to the capsule's output buffer, or create a new buffer */
                let mut stdout = STDOUT.lock();
                match stdout.get_mut(&cid)
                {
                    Some(entry) => entry.push(character),
                    None =>
                    {
                        let mut v = Vec::new();
                        v.push(character);
                        stdout.insert(cid, v);
                    }
                }
            }
        },
        None => return Err(Cause::CapsuleBadID)
    }

    Ok(())
}

/* read a character from the user for the given capsule.
   this will either read from the capsule's buffer that's filled
   by the user interface capsule, or this is the user interface
   capsule and we'll read the input from the hardware.
   this call does not block
   <= returns read character or an error code
*/
pub fn getc(cid: CapsuleID) -> Result<char, Cause>
{
    /* find the capsule we're trying to read from */
    match CAPSULES.lock().get_mut(&cid)
    {
        Some(capsule) =>
        {
            /* if this capsule can read direct from the hardware, then let it */
            if capsule.has_property(CapsuleProperty::ConsoleRead)
            {
                return match hardware::read_debug_char()
                {
                    Some(c) => Ok(c),
                    None => Err(Cause::CapsuleStdinEmpty)
                };
            }
            else
            {
                /* read from the capsule's buffer, or give up */
                let mut stdin = STDIN.lock();
                if let Some(entry) = stdin.get_mut(&cid)
                {
                    if entry.len() > 0
                    {
                        return Ok(entry.remove(0));
                    }
                }
                
                return Err(Cause::CapsuleStdinEmpty);
            }
        },
        None => return Err(Cause::CapsuleBadID)
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
