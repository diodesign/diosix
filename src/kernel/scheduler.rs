/* diosix virtual CPU scheduler for containers
 *
 * (c) Chris Williams, 2018-2019
 *
 * See LICENSE for usage and copying.
 */

use error::Cause;
use spin::Mutex;
use alloc::boxed::Box;
use alloc::collections::vec_deque::VecDeque;
use thread::{Thread, Priority};
use cpu::{context_switch, Core};

pub type TimesliceCount = u64;

/* prevent CPU time starvation: allow a normal thread to run after this number of timeslices
have been spent running high priority threads */
const HIGH_PRIO_TIMESLICES_MAX: TimesliceCount = 10;

/* initialize preemptive scheduling system
Call only once, and only by the boot cpu
<= return OK for success, or an error code */
pub fn init(device_tree_buf: &u8) -> Result<(), Cause>
{
    /* set up a periodic timer that we can use to pause and restart threads
    once they've had enough CPU time. pass along the device tree so the
    platform-specific code can find the necessary hardware timer */
    match platform::common::timer::init(device_tree_buf)
    {
        true => Ok(()),
        false => Err(Cause::SchedTimerBadConfig)
    }
}

/* activate preemptive multitasking. each CPU core should call this
to start running software threads */
pub fn start()
{
    platform::common::timer::start();
}

/* a thread has been running for one timeslice, triggering a timer interrupt.
this is the handler of that interrupt: find something else to run, if necessary,
or return to whatever we were running... */
pub fn timer_irq()
{
    /* check to see if there's anything waiting to be picked up for this CPU queue from a global queue.
    if so, then adopt it so it can get a chance to run */
    match GLOBAL_QUEUES.lock().dequeue()
    {
        /* we've found a thread to run, so switch to that */
        Some(orphan) => context_switch(orphan),

        /* otherwise, try to take a thread waiting for this CPU core and run it */
        _ => match Core::dequeue()
        {
            Some(thread) => context_switch(thread), /* waiting thread found, queuing now */
            _ => () /* nothing waiting */
        }
    };

    /* tell the timer system to call us back soon */
    let now: u64 = platform::common::timer::now();
    let next: u64 = now + 10000000;
    platform::common::timer::next(next);
}

/* queue thread in global wait list */
pub fn queue(to_queue: Thread)
{
    GLOBAL_QUEUES.lock().queue(to_queue);
}

/* maintain a simple two-level round-robin scheduler per CPU. we can make it more fancy later.
the hypervisor tries to dish out CPU time fairly among containers, and let the
container supervisors work out how best to allocate their time to userspace code.
picking the next thread to run should be O(1) or as close as possible to it. */
pub struct ScheduleQueues
{
    high: VecDeque<Thread>,
    low: VecDeque<Thread>,
    high_timeslices: TimesliceCount
}

/* these are the global wait queues. while each physical CPU core gets its own pair
of high-normal wait queues, threads waiting to be assigned to a CPU sit in these global queues.
when a CPU runs out of queues, it pulls one from these queues.
when a CPU has too many threads, it pushes one onto one of these wait lists */
lazy_static!
{
    static ref GLOBAL_QUEUES: Mutex<Box<ScheduleQueues>> = Mutex::new(box ScheduleQueues::new());
}

impl ScheduleQueues
{
    /* initialize a new set of scheduler queues */
    pub fn new() -> ScheduleQueues
    {
        ScheduleQueues
        {
            high: VecDeque::<Thread>::new(),
            low: VecDeque::<Thread>::new(),
            high_timeslices: 0
        }
    }

    /* run the given thread by switching to its supervisor context.
    this also updates NORM_PRIO_TICKS. if the current physical CPU was already running a
    thread, that thread is queued up in the waiting list by context_switch() */
    pub fn run(&mut self, to_run: Thread)
    {
        /* if we're about to run a normal thread, then reset counter since a normal thread ran.
        if we're running a non-normal thread, then increase the count. */
        match to_run.get_priority()
        {
            Priority::Normal => self.high_timeslices = 0,
            Priority::High => self.high_timeslices = self.high_timeslices + 1
        };

        context_switch(to_run);
    }

    /* add the given thread to the appropriate waiting queue. put it to the back
    so that other threads get a chance to run */
    pub fn queue(&mut self, to_queue: Thread)
    {
        match to_queue.get_priority()
        {
            Priority::High => self.high.push_back(to_queue),
            Priority::Normal => self.low.push_back(to_queue)
        }
    }

    /* remove a thread from the waiting list queues, selected by priority with safeguards to
    prevent CPU time starvation. Returns selected thread or None for no other threads waiting */
    pub fn dequeue(&mut self) -> Option<Thread>
    {
        /* has a normal thread been waiting for ages? */
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
