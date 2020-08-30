/* diosix virtual CPU scheduler
 *
 * This is, for now, really really simple.
 * Making it fairer and adaptive to workloads is the ultimate goal.
 * 
 * (c) Chris Williams, 2018-2020.
 *
 * See LICENSE for usage and copying.
 */

use spin::Mutex;
use alloc::collections::vec_deque::VecDeque;
use hashbrown::hash_map::HashMap;
use super::error::Cause;
use super::vcore::{VirtualCore, Priority};
use super::pcore::{self, PhysicalCore, PhysicalCoreID};
use super::hardware;
use super::message;

pub type TimesliceCount = u64;

/* prevent physical CPU time starvation: allow a normal virtual core to run after this number of timeslices
have been spent running high priority virtual cores */
const HIGH_PRIO_TIMESLICES_MAX: TimesliceCount = 10;

/* number of microseconds a virtual core is allowed to run */
const TIMESLICE_LENGTH: u64 = 50 * 1000; /* 50 milliseconds */

/* number of microseconds a system maintence core (one that can't run supervisor code) must wait
before looking for fixed work to do. also the length in between application cores can
attempt to perform housekeeping */
const MAINTENANCE_LENGTH: u64 = 5 * 1000000; /* five seconds */

/* a physical core will perform background housekeeping after this
many number of searches for a virtual core to run in a row without success */
const HOUSEKEEP_AFTER: usize = 1024;

/* these are the global wait queues. while each physical CPU core gets its own pair
of high-normal wait queues, virtual cores waiting to be assigned to a physical CPU sit in these global queues.
when a physical CPU runs out of queued virtual cores, it pulls one from these global queues.
a physical CPU core can ask fellow CPUs to push virtual cores onto the global queues via messages */
lazy_static!
{
    static ref GLOBAL_QUEUES: Mutex<ScheduleQueues> = Mutex::new(ScheduleQueues::new());
    static ref WORKLOAD: Mutex<HashMap<PhysicalCoreID, usize>> = Mutex::new(HashMap::new());
    static ref LAST_HOUSEKEEP_CHECK: Mutex<u64> = Mutex::new(0);
}

#[derive(PartialEq, Clone, Copy, Debug)]
pub enum SearchMode
{
    MustFind, /* when searching for something to run, keep looping until successful */
    CheckOnce /* search just once for something else to run, return to environment otherwise */
}

/* queue a virtual core in global wait list */
pub fn queue(to_queue: VirtualCore)
{
    GLOBAL_QUEUES.lock().queue(to_queue);
}

/* activate preemptive multitasking. each physical CPU core should call this
   to start running workloads - be them user/supervisor or management tasks
   <= returns OK, or error code on failure */
pub fn start() -> Result<(), Cause>
{
    hardware::scheduler_timer_start();
    Ok(())
}

/* find something else to run, or return to whatever we were running if allowed.
   call this function when a virtual core's timeslice has expired, or it has crashed
   or stopped running and we can't return to it. this function will return regardless
   if this physical CPU core is unable to run virtual cores.
   => search_mode = define whether or not to continue searching for another
   virtual core to run, or check once to see if something else is waiting */
pub fn run_next(search_mode: SearchMode)
{
    /* check to see if any housekeeping is needed */
    housekeeping();

    /* if this core can run supervisor-level code then find it some work to do */
    if pcore::PhysicalCore::smode_supported()
    {
        /* keep looping until we've found something to switch to if must_switch
        is set to true */
        loop
        {
            let mut something_found = true;

            /* check to see if there's anything waiting to be picked up for this
            physical CPU from a global queue. if so, then adopt it so it can get a chance to run */
            match GLOBAL_QUEUES.lock().dequeue()
            {
                /* we've found a virtual CPU core to run, so switch to that */
                Some(orphan) =>
                {
                    let mut workloads =  WORKLOAD.lock();

                    /* increment counter of how many virtual cores this physical CPU core
                    has taken from the global queue */
                    if let Some(count) = workloads.get_mut(&PhysicalCore::get_id())
                    {
                        *count = *count + 1;
                    }
                    else
                    {
                        workloads.insert(PhysicalCore::get_id(), 1);
                    }

                    pcore::context_switch(orphan);
                },

                /* otherwise, try to take a virtual CPU core waiting for this physical CPU core and run it */
                _ => match PhysicalCore::dequeue()
                {
                    Some(virtcore) => pcore::context_switch(virtcore), /* waiting virtual CPU core found, queuing now */
                    _ => something_found = false /* nothing else to run */
                }
            }

            /* if we've found something, or only searching once, exit the search loop */
            if something_found == true || search_mode == SearchMode::CheckOnce
            {
                break;
            }
        }

        /* tell the timer system to call us back soon */
        hardware::scheduler_timer_next(TIMESLICE_LENGTH);
    }
    else
    {
        hardware::scheduler_timer_next(MAINTENANCE_LENGTH); /* we'll be back some time later */
    }
}

/* perform any housekeeping duties defined by the various parts of the system */
fn housekeeping()
{
    /* don't busy wait for housekeeping lock: check once and move on */
    let mut last_check = match LAST_HOUSEKEEP_CHECK.try_lock()
    {
        Some(value) => value,
        None => return
    };

    /* only perform housekeeping once every MAINTENANCE_LENGTH microseconds */
    match hardware::scheduler_timer_now()
    {
        Some(time_now) =>
        {
            /* wait until we're at least MAINTENANCE_LENGTH into boot */
            if time_now > MAINTENANCE_LENGTH
            {
                if time_now - *last_check < MAINTENANCE_LENGTH
                {
                    /* not enough MAINTENANCE_LENGTH time has passed */
                    return;
                }
                /* mark when we last performed housekeeping */
                *last_check = time_now;
            }
            else
            {
                /* flush debug and bail out */
                debughousekeeper!();
                return;
            }
        },
        None =>
        {
            /* no timer. output debug and bail out */
            debughousekeeper!();
            return;
        }
    }

    debughousekeeper!(); /* drain the debug logs to the debug hardware port */
    heaphousekeeper!(); /* return any unused regions of physical memory */
    physmemhousekeeper!(); /* tidy up any physical memory structures */

    /* if the global queues are empty then work out which physical CPU core
    has the most number of virtual cores and is therefore the busiest */
    let global_queue_lock = GLOBAL_QUEUES.lock();
    if global_queue_lock.total_queued() > 0
    {
        let mut highest_count = 0;
        let mut busiest_pcore: Option<PhysicalCoreID> = None;
        for (&pcoreid, &vcore_count) in WORKLOAD.lock().iter()
        {
            if vcore_count > highest_count
            {
                highest_count = vcore_count;
                busiest_pcore = Some(pcoreid);
            }
        }

        /* ask the busiest core to send one virtual core back to the global queue
        but only if it has enough to share: it must have more than one virtual core */
        if highest_count > 1
        {
            if let Some(pid) = busiest_pcore
            {
                let m = message::Message::new(message::Recipient::send_to_pcore(pid),
                                                message::MessageContent::DisownQueuedVirtualCore);
                match message::send(m)
                {
                    Err(e) => hvalert!("Failed to message physical CPU {} during load balancing: {:?}", pid, e),
                    Ok(()) => ()
                };
            }
        }
    }
}

/* maintain a simple two-level round-robin scheduler per physical CPU core. we can make it more fancy later.
the hypervisor tries to dish out physical CPU time fairly among capsules, and let the
capsule supervisors work out how best to allocate their time to userspace code.
picking the next virtual CPU core to run should be O(1) or as close as possible to it. */
pub struct ScheduleQueues
{
    high: VecDeque<VirtualCore>,
    low: VecDeque<VirtualCore>,
    high_timeslices: TimesliceCount
}

impl ScheduleQueues
{
    /* initialize a new set of scheduler queues */
    pub fn new() -> ScheduleQueues
    {
        ScheduleQueues
        {
            high: VecDeque::<VirtualCore>::new(),
            low: VecDeque::<VirtualCore>::new(),
            high_timeslices: 0
        }
    }

    /* run the given virtual core by switching to its supervisor context.
    this also updates NORM_PRIO_TICKS. if the current physical CPU was already running a
    virtual core, that virtual core is queued up in the waiting list by context_switch() */
    pub fn run(&mut self, to_run: VirtualCore)
    {
        /* if we're about to run a normal virtual core, then reset counter since a normal virtual core ran.
        if we're running a non-normal virtual core, then increase the count. */
        match to_run.get_priority()
        {
            Priority::Normal => self.high_timeslices = 0,
            Priority::High => self.high_timeslices = self.high_timeslices + 1
        };

        pcore::context_switch(to_run);
    }

    /* add the given virtual core to the appropriate waiting queue. put it to the back
    so that other virtual cores get a chance to run */
    pub fn queue(&mut self, to_queue: VirtualCore)
    {
        match to_queue.get_priority()
        {
            Priority::High => self.high.push_back(to_queue),
            Priority::Normal => self.low.push_back(to_queue)
        }
    }

    /* remove a virtual core from the waiting list queues, selected by priority with safeguards to
    prevent CPU time starvation. Returns selected virtual core or None for no other virtual cores waiting */
    pub fn dequeue(&mut self) -> Option<VirtualCore>
    {
        /* has a normal virtual core been waiting for ages? */
        if self.high_timeslices > HIGH_PRIO_TIMESLICES_MAX
        {
            match self.low.pop_front()
            {
                Some(t) => return Some(t),
                None => ()
            };
        }

        /* check the high priority queue for anything waiting.
        if not, then try the normal priority queue */
        match self.high.pop_front()
        {
            Some(t) => Some(t),
            None => self.low.pop_front()
        }
    }

    /* return the total number of virtual cores queued */
    pub fn total_queued(&self) -> usize
    {
        self.high.len() + self.low.len()
    }
}
