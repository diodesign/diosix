/* diosix virtual CPU scheduler for containers
 *
 * (c) Chris Williams, 2018.
 *
 * See LICENSE for usage and copying.
 */

use error::Cause;
use spin::Mutex;
use alloc::boxed::Box;
use alloc::collections::linked_list::LinkedList;
use container::ContainerName;
use platform::common::cpu::SupervisorState;

/* one tick represents one scheduling period rather than a clock tick */
type Ticks = usize;

/* initialize preemptive scheduling system's timer. this is used to interrupt the running
virtual CPU thread so another can be run next
<= return OK for success, or an error code */
pub fn init(device_tree_buf: &u8) -> Result<(), Cause>
{
    match platform::common::timer::init(device_tree_buf)
    {
        true => Ok(()),
        false => Err(Cause::SchedTimerBadConfig)
    }
}

/* activate hardware timer and start running threads */
pub fn start()
{
    platform::common::timer::start();
}

/* handle the timer kicking off an interrupt */
pub fn timer_irq()
{
    let now: u64 = platform::common::timer::now();
    let next: u64 = now + 20000000;
    platform::common::timer::next(next);
    klog!("timer tick");
}

/* maintain a simple two-level round-robin scheduler. we can make it more fancy later.
the hypervisor tries to dish out CPU time fairly among evironments, and let the
container supervisors work out how best to allocate their time to userspace code.
picking the next virtual CPU thread to run should be O(1) or as close as possible to it.

if a High priority container is waiting to run, then schedule it, unless a Normal
container hasn't been run within a particular timeframe and a Normal container is
waiting. if no High is waiting, then run a Normal. if no High or Normal is waiting, then
wait unil work comes along. */
#[derive(Copy, Clone)]
pub enum Priority
{
    High,
    Normal
}

/* prevent CPU time starvation: allow a normal thread to run after this number of timer ticks */
const NORM_PRIO_TICKS_MAX: Ticks = 10;

lazy_static!
{
    /* acquire HIGH_PRIO_THREADS, LOW_PRIO_THREADS etc lock before accessing any threads.
    all threads in _PRIO_THREADS are waiting to run. running threads should be in the running list */
    static ref HIGH_PRIO_WAITING: Mutex<Box<LinkedList<Thread>>> = Mutex::new(box LinkedList::new());
    static ref NORM_PRIO_WAITING: Mutex<Box<LinkedList<Thread>>> = Mutex::new(box LinkedList::new());
    /* number of ticks since a normal priority thread was run */
    static ref NORM_PRIO_TICKS: Mutex<Box<Ticks>> = Mutex::new(box (0 as Ticks));
}

/* the scheduler is focused on virtual CPU threads within containers. a thread object is either
in a waiting queue awaiting CPU time, or is runnng and held in a physical cpu Core struct.
if you remove a thread object from the queue and don't place it back in a queue or Core structure,
then the thread will be dropped, deallocated and destroyed. */
pub struct Thread
{
    container: ContainerName,
    priority: Priority,
    state: SupervisorState
}

impl Thread
{
    /* return reference to thread's physical CPU state */
    pub fn get_state_as_ref(&self) -> &SupervisorState { &self.state }
}

/* create a new virtual CPU thread for a container
   => name = name of the container
      entry = pointer to thread's start address
      stack = stack pointer value to use
      priority = thread priority */
pub fn create_thread(name: &str, entry: fn () -> (), stack: usize, priority: Priority)
{
    let new_thread = Thread
    {
        container: ContainerName::from(name),
        priority: priority,
        state: platform::common::cpu::supervisor_state_from(entry, stack)
    };

    /* add thread to correct priority queue */
    queue_thread(new_thread);
}

/* run the given thread by switching to its supervisor context.
this also zeroes NORM_PRIO_TICKS if this is a normal priority thread. */
pub fn run_thread(to_run: Thread)
{
    /* if we're about to run a normal thread, then reset ticks since a normal thread ran */
    match to_run.priority
    {
        Priority::Normal =>
        {
            let mut ticks = NORM_PRIO_TICKS.lock();
            **ticks = 0;
        },
        _ => ()
    }

    ::cpu::context_switch(to_run);
}

/* add the given thread to the appropriate waiting queue. put it to the back
so that other threads get a chance to run */
pub fn queue_thread(to_queue: Thread)
{
    let mut list = match to_queue.priority
    {
        Priority::High => HIGH_PRIO_WAITING.lock(),
        Priority::Normal => NORM_PRIO_WAITING.lock()
    };

    list.push_back(to_queue);
}

/* remove a thread from the waiting list queues, selected by priority with safeguards to
prevent CPU time starvation. Returns selected thread or None for no other threads waiting */
pub fn dequeue_thread() -> Option<Thread>
{
    /* has a normal thread been waiting for ages? */
    let ticks = NORM_PRIO_TICKS.lock();
    if **ticks > NORM_PRIO_TICKS_MAX
    {
        match NORM_PRIO_WAITING.lock().pop_front()
        {
            Some(t) => return Some(t),
            None => ()
        }
    }

    /* check the high priority queue for anything waiting.
    if not, then try the normal priority queue */
    match HIGH_PRIO_WAITING.lock().pop_front()
    {
        Some(t) => Some(t),
        None => NORM_PRIO_WAITING.lock().pop_front()
    }
}