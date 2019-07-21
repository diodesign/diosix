/* diosix virtual CPU scheduler
 *
 * (c) Chris Williams, 2018-2019
 *
 * See LICENSE for usage and copying.
 */

use error::Cause;
use spin::Mutex;
use alloc::collections::vec_deque::VecDeque;
use vcore::{VirtualCore, Priority};
use cpu::{self, Core};

pub type TimesliceCount = u64;

/* prevent physical CPU time starvation: allow a normal virtual core to run after this number of timeslices
have been spent running high priority virtual cores */
const HIGH_PRIO_TIMESLICES_MAX: TimesliceCount = 10;

/* initialize preemptive scheduling system
Call only once, and only by the boot cpu
<= return OK for success, or an error code */
pub fn init(device_tree_buf: &u8) -> Result<(), Cause>
{
    /* set up a periodic timer that we can use to pause and restart virtual cores
    once they've had enough physical CPU time. pass along the device tree so the
    platform-specific code can find the necessary hardware timer */
    match platform::timer::init(device_tree_buf)
    {
        true => Ok(()),
        false => Err(Cause::SchedTimerBadConfig)
    }
}

/* activate preemptive multitasking. each physical CPU core should call this
to start running virtual CPU cores. Physical CPU cores that can't run user and supervisor-level
code aren't allowed to join the scheduler: these cores are likely auxiliary or
management CPUs that have to park waiting for interrupts */
pub fn start()
{
    if platform::cpu::features_priv_check(platform::cpu::PrivilegeMode::User) == true
    {
        platform::timer::start();
    }
    else
    {
        hvlog!("Can't join the scheduler, awaiting IRQs");
    }
}

/* a virtual CPU core has been running for one timeslice, triggering a timer interrupt.
this is the handler of that interrupt: find something else to run, if necessary,
or return to whatever we were running... */
pub fn timer_irq()
{
    /* check to see if there's anything waiting to be picked up for this physical CPU queue from a global queue.
    if so, then adopt it so it can get a chance to run */
    match GLOBAL_QUEUES.lock().dequeue()
    {
        /* we've found a virtual CPU core to run, so switch to that */
        Some(orphan) => cpu::context_switch(orphan),

        /* otherwise, try to take a virtual CPU core waiting for this physical CPU core and run it */
        _ => match Core::dequeue()
        {
            Some(virtcore) => cpu::context_switch(virtcore), /* waiting virtual CPU core found, queuing now */
            _ => () /* nothing waiting */
        }
    };

    /* tell the timer system to call us back soon */
    let now: u64 = platform::timer::now();
    let next: u64 = now + 10000000;
    platform::timer::next(next);
}

/* queue virtual core in global wait list */
pub fn queue(to_queue: VirtualCore)
{
    GLOBAL_QUEUES.lock().queue(to_queue);
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

/* these are the global wait queues. while each physical CPU core gets its own pair
of high-normal wait queues, virtual cores waiting to be assigned to a physical CPU sit in these global queues.
when a physical CPU runs out of queues, it pulls one from these queues.
when a physical CPU has too many virtual cores, it pushes one onto one of these wait lists */
lazy_static!
{
    static ref GLOBAL_QUEUES: Mutex<ScheduleQueues> = Mutex::new(ScheduleQueues::new());
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
