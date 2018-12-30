/* diosix virtual CPU scheduler for supervisor environments
 *
 * (c) Chris Williams, 2018.
 *
 * See LICENSE for usage and copying.
 */

use spin::Mutex;
use alloc::boxed::Box;
use alloc::collections::linked_list::LinkedList;
use environment::EnvironmentName;
use platform::common::cpu::SupervisorState;
use ::cpu;

type Ticks = usize;

/* maintain a simple two-level round-robin scheduler. we can make it more fancy later.
the hypervisor tries to dish out CPU time fairly among evironments, and let the
supervisors work out how best to allocate their time to userspace code.
picking the next environment to run should be O(1) or as close as possible to it.

if a High priority environment is waiting to run, then schedule it, unless a Normal
envionment hasn't been run within a particular timeframe and a Normal environment is
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

/* the scheduler is focused on virtual CPU threads within environments. a thread object is either
in a waiting queue awaiting CPU time, or is runnng and held in a physical cpu Core struct.
if you remove a thread object from the queue and don't place it back in a queue or Core structure,
then the thread will be dropped, deallocated and destroyed. */
pub struct Thread
{
    environment: EnvironmentName,
    priority: Priority,
    state: SupervisorState
}

impl Thread
{
    /* return reference to thread's physical CPU state */
    pub fn get_state_as_ref(&self) -> &SupervisorState { &self.state }
}

/* create a new virtual CPU thread for an environment
   => env_name = name of the environment
      entry = pointer to thread's start address
      stack = stack pointer value to use
      priority = thread priority */
pub fn create_thread(env_name: &str, entry: fn () -> (), stack: usize, priority: Priority)
{
    let new_thread = Thread
    {
        environment: EnvironmentName::from(env_name),
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

    cpu::context_switch(to_run);
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