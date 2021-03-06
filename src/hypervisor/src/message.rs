/* diosix hypervisor's system for passing messages between physical CPU cores and services
 *
 * (c) Chris Williams, 2019-2020.
 *
 * See LICENSE for usage and copying.
 */

use super::lock::Mutex;
use alloc::collections::vec_deque::VecDeque;
use alloc::string::String;
use hashbrown::hash_map::HashMap;
use super::error::Cause;
use super::service::{self, ServiceType};
use super::capsule::CapsuleID;
use super::pcore::{PhysicalCoreID, PhysicalCore};

/* here's how message passing works, depending on the target:
    * To an individual physical core:
        1. locate the physical core's message queue in MAILBOXES
        2. insert the message at the end of the queue
        3. interrupt the physical CPU core to check its mailbox
    * To all physical cores:
        1. iterate over each physical core in MAILBOXES
        2. insert a copy of the message in the message queue of each physical CPU
        3. interrupt each physical CPU core to check its mailbox
    * To a service registered by a capsule:
        1. locate the service's mailbox
        2. insert the message into the mailbox
        3. raise an interrupt or wait for the capsule to poll the mailbox
*/

/* maintain a mailbox of messages per physical CPU core */
lazy_static!
{
    static ref MAILBOXES: Mutex<HashMap<PhysicalCoreID, VecDeque<Message>>> = Mutex::new("mailbox", HashMap::new());
}

/* create a mailbox for physical CPU core coreid */
pub fn create_mailbox(coreid: PhysicalCoreID)
{
    MAILBOXES.lock().insert(coreid, VecDeque::<Message>::new());
}

#[derive(Clone)]
pub enum Sender
{
    PhysicalCore(PhysicalCoreID),
    Capsule(CapsuleID),
    Hypervisor
}

#[derive(Clone, Copy)]
pub enum Recipient
{
    Broadcast,                      /* send to all physical CPU cores */
    PhysicalCore(PhysicalCoreID),   /* send to a single physical CPU core */
    Service(ServiceType)              /* send to a single registered service */
}

impl Recipient
{
    /* broadcast message to all physical cores */
    pub fn send_to_all() -> Recipient { Recipient::Broadcast }

    /* send to a particular physical core */
    pub fn send_to_pcore(id: PhysicalCoreID) -> Recipient
    {
        Recipient::PhysicalCore(id)
    }

    /* send to a particular capsule-hosted service */
    pub fn send_to_service(stype: ServiceType) -> Recipient
    {
        Recipient::Service(stype)
    }
}

#[derive(Clone, Debug)]
pub enum MessageContent
{
    HypervisorDebugStr(String),
    CapsuleConsoleStr(String),
    DisownQueuedVirtualCore
}

#[derive(Clone)]
pub struct Message
{
    sender: Sender,
    receiver: Recipient,
    data: MessageContent
}

impl Message
{
    /* create a new message
       => recv = end point to send the message to
          data = message to send to the recipient
       <= returns message structure
    */
    pub fn new(recv: Recipient, data: MessageContent) -> Result<Message, Cause>
    {
        Ok(Message
        {
            receiver: recv,
            
            /* determine sender from message type */
            sender: match data
            {
                MessageContent::HypervisorDebugStr(_) => Sender::Hypervisor,
                MessageContent::CapsuleConsoleStr(_) => match PhysicalCore::get_capsule_id()
                {
                    Some(id) => Sender::Capsule(id),
                    None =>
                    {
                        hvdebug!("BUG: Sending {:?} from non-existent capsule", data);
                        return Err(Cause::CapsuleBadID);
                    }
                },
                MessageContent::DisownQueuedVirtualCore => Sender::PhysicalCore(PhysicalCore::get_id())
            },

            data
        })
    }

    pub fn get_receiver(&self) -> Recipient
    {
        self.receiver
    }
}

/* send the given message msg, consuming it so it can't be reused or resent */
pub fn send(msg: Message) -> Result<(), Cause>
{
    let receiver = msg.receiver;
    match receiver
    {
        /* iterate over all physical CPU cores */
        Recipient::Broadcast =>
        {
            for (_, mailbox) in MAILBOXES.lock().iter_mut()
            {
                mailbox.push_back(msg.clone())
            }
        },

        /* send to a particular physical CPU core */
        Recipient::PhysicalCore(pid) =>
        {
            if let Some(mailbox) = MAILBOXES.lock().get_mut(&pid)
            {
                mailbox.push_back(msg);
            }
            else
            {
                return Err(Cause::PhysicalCoreBadID);
            }
        },

        /* send to a service */
        Recipient::Service(_) =>
        {
            return service::send(msg);
        }
    };

    Ok(())
}
