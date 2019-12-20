/* diosix capsule-provided service management

 * (c) Chris Williams, 2019.
 *
 * See LICENSE for usage and copying.
 */

use spin::Mutex;
use hashbrown::hash_map::{self, HashMap, Entry};
use alloc::collections::vec_deque::VecDeque;
use super::message;
use super::error::Cause;
use super::capsule::{self, CapsuleID};

pub type ServiceID = usize;

/* todo: a fixed list of known system services,
such as video, sound, serial, network, etc
that privileged / trusted capsules can register.
then other capsules can message those services
to access those underlying resources. */

/* maintain a table of registered services */
lazy_static!
{
    static ref SERVICES: Mutex<HashMap<ServiceID, Service>> = Mutex::new(HashMap::new());
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
}

/* register a service for a capsule. this will fail if the service is
   already registered or if the capsule has no right to run the service
   or if the capsule doesn't exist. 
    => sid = ID of service to register
       cid = ID of capsule to handle this service
    <= return Ok for success, or a failure code */
pub fn register(sid: ServiceID, cid: CapsuleID) -> Result<(), Cause>
{
    match capsule::is_service_allowed(cid, sid)
    {
        Some(flag) => if flag == false
        {
            return Err(Cause::ServiceNotAllowed);
        },
        None => return Err(Cause::CapsuleBadID)
    };

    let service = Service
    {
        capsuleid: cid,
        msgs: VecDeque::new()
    };

    /* ensure we do not double register a service */
    if let Entry::Vacant(v) = SERVICES.lock().entry(sid)
    {
        v.insert(service);
        return Ok(());
    }
    else
    {
        return Err(Cause::ServiceAlreadyRegistered)
    }
}

/* deregister a service so that its capsule is no longer responsible for it
   => sid = service to deregister
   <= Ok for success, or an error code for failure */
pub fn deregister(sid: ServiceID) -> Result<(), Cause>
{
    Err(Cause::NotImplemented)
}

/* send the given message msg to a registered service */
pub fn send(msg: message::Message) -> Result<(), Cause>
{
    let sid = match msg.get_receiver()
    {
        message::Recipient::Service(sid) => sid,
        _ => return Err(Cause::MessageBadType)
    };

    if let Some(service) = SERVICES.lock().get_mut(&sid)
    {
        service.queue(msg);
        Ok(())
    }
    else
    {
        return Err(Cause::ServiceNotAllowed)
    }
}