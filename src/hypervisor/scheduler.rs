/* diosix virtual CPU scheduler
 *
 * (c) Chris Williams, 2018-2019
 *
 * See LICENSE for usage and copying.
 */

use spin::Mutex;
use alloc::collections::vec_deque::VecDeque;
use super::error::Cause;
use super::vcore::{VirtualCore, Priority};
use super::cpu::{self, Core};
use super::hardware;

pub type TimesliceCount = u64;

/* prevent physical CPU time starvation: allow a normal virtual core to run after this number of timeslices
have been spent running high priority virtual cores */
const HIGH_PRIO_TIMESLICES_MAX: TimesliceCount = 10;

/* number of microseconds a virtual core is allowed to run */
const TIMESLICE_LENGTH: u64 = 1000;

/* these are the global wait queues. while each physical CPU core gets its own pair
of high-normal wait queues, virtual cores waiting to be assigned to a physical CPU sit in these global queues.
when a physical CPU runs out of queues, it pulls one from these queues.
when a physical CPU has too many virtual cores, it pushes one onto one of these wait lists */
lazy_static!
{
    static ref GLOBAL_QUEUES: Mutex<ScheduleQueues> = Mutex::new(ScheduleQueues::new());
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
   or stopped running and we can't return to it.
   => must_switch = set to true to never return without switching to a new thread */
pub fn run_next(must_switch: bool)
{
    /* if this core can run supervisor-level code then find it some work to do */
    if cpu::Core::smode_supported()
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
                Some(orphan) => cpu::context_switch(orphan),

                /* otherwise, try to take a virtual CPU core waiting for this physical CPU core and run it */
                _ => match Core::dequeue()
                {
                    Some(virtcore) => cpu::context_switch(virtcore), /* waiting virtual CPU core found, queuing now */
                    _ => something_found = false /* nothing else to run */
                }
            }

            if must_switch == false || (must_switch && something_found == true)
            {
                break;
            }

            /* do some housekeeping seeing as we can't run workloads, either
            because there's nothing to run or because we can't */
            housekeeping();
        }
    }
    else
    {
        housekeeping(); /* can't run workloads so find something else to do */
    }

    /* tell the timer system to call us back soon */
    hardware::scheduler_timer_next(TIMESLICE_LENGTH);
}

/* perform any housekeeping duties */
fn housekeeping()
{
    hvdrain!(); /* drain the debug logs to the debug hardware port */
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

        cpu::context_switch(to_run);
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
}
