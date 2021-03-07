/* diosix capsule-provided service management

 * (c) Chris Williams, 2019-2020.
 *
 * See LICENSE for usage and copying.
 */

use super::lock::Mutex;
use hashbrown::hash_map::{HashMap, Entry};
use alloc::collections::vec_deque::VecDeque;
use alloc::vec::Vec;
use super::message;
use super::error::Cause;
use super::capsule::{self, CapsuleID};

/* available type of services that can be offered by a capsule */
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub enum ServiceType
{
    ConsoleInterface = 0 /* act as the console interface manager */
}

pub fn usize_to_service_type(stype: usize) -> Result<ServiceType, Cause>
{
    match stype
    {
        0 => Ok(ServiceType::ConsoleInterface),
        _ => Err(Cause::ServiceNotFound)
    }
}

/* select either a particular service or all services */
pub enum SelectService
{
    AllServices,
    SingleService(ServiceType)
}

/* todo: a fixed list of known system services,
such as video, sound, serial, network, etc
that privileged / trusted capsules can register.
then other capsules can message those services
to access those underlying resources. */

/* maintain a table of registered services */
lazy_static!
{
    static ref SERVICES: Mutex<HashMap<ServiceType, Service>> = Mutex::new("system service table", HashMap::new());
}

/* return true if the given service type is registered */
pub fn is_registered(stype: ServiceType) -> bool
{
    let tbl = SERVICES.lock();
    tbl.contains_key(&stype)
}

/* describe an individual service */
struct Service
{
    capsuleid: CapsuleID,       /* capsule that's registered this service */
    msgs: VecDeque<message::Message>  /* queue of messages to deliver to service */
}

impl Service
{
    pub fn queue(&mut self, msg: message::Message)
    {
        self.msgs.push_front(msg);
    }

    pub fn get_capsule_id(&self) -> CapsuleID { self.capsuleid }
}

/* register a service for a capsule. this will fail if the
   capsule has no right to run the service, or if the capsule doesn't exist,
   or if another capsule has already claimed the service type.
   be aware if the capsule has already claimed the service, it will
   return Err(Cause::ServiceAlreadyOwner). this will be the result if a
   restarted capsule registers its service(s) again. services aren't released
   during a restart to provide a non-stop continuation of services.
    => stype = type of service to register
       cid = ID of capsule to handle this service
    <= return Ok for success, or a failure code */
pub fn register(stype: ServiceType, cid: CapsuleID) -> Result<(), Cause>
{
    if capsule::is_service_allowed(cid, stype)? == false
    {
        return Err(Cause::ServiceNotAllowed);
    }

    let service = Service
    {
        capsuleid: cid,
        msgs: VecDeque::new()
    };

    match SERVICES.lock().entry(stype)
    {
        Entry::Vacant(v) =>
        {
            v.insert(service);
        },
        Entry::Occupied(o) => if o.get().get_capsule_id() != cid
        {
            /* another capsule owns this service */
            return Err(Cause::ServiceAlreadyRegistered);
        }
        else
        {
            /* this capsule already owns this service */
            return Err(Cause::ServiceAlreadyOwner)
        }
    }

    Ok(())
}

/* deregister one or all services belonding to a capsule
   so that it is no longer responsible for them
   => stype = service to deregister, or None for all of them
      cid = ID of capsule to strip of its services
   <= Ok for success, or an error code for failure */
pub fn deregister(stype: SelectService, cid: CapsuleID) -> Result<(), Cause>
{
    let mut tbl = SERVICES.lock();
    let mut to_remove = Vec::new();

    for (registered, owner) in (&tbl).iter()
    {
        /* remove either everything that matches the capsule ID, or a particular service */
        match stype
        {
            SelectService::AllServices => if owner.get_capsule_id() == cid
            {
                to_remove.push(*registered);
            },
            SelectService::SingleService(s) => if owner.get_capsule_id() == cid && s == *registered
            {
                to_remove.push(*registered);
            }
        }
    }

    /* now remove the vicims */
    for victim in to_remove
    {
        tbl.remove(&victim);
    }

    Ok(())
}

/* send the given message msg to a registered service */
pub fn send(msg: message::Message) -> Result<(), Cause>
{
    let stype = match msg.get_receiver()
    {
        message::Recipient::Service(stype) => stype,
        _ => return Err(Cause::MessageBadType)
    };

    if let Some(service) = SERVICES.lock().get_mut(&stype)
    {
        service.queue(msg);
        Ok(())
    }
    else
    {
        return Err(Cause::ServiceNotAllowed)
    }
}