/* diosix high-level hypervisor's mutex primitive
 *
 * Provide reentrant mutex locks for critical
 * data structures. this means when a physical
 * core holds a lock and then tries to lock it
 * again, this operation will succeed.
 * 
 * this is so that if a core holds a lock
 * and is interrupted, it can regain access
 * to the locked data, use it, and release it.
 * 
 * use lock() to acquire an exclusive lock
 * drop the lock to release it
 * 
 * (c) Chris Williams, 2021.
 *
 * See LICENSE for usage and copying.
 */

use core::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use core::cell::UnsafeCell;
use core::ops::{Deref, DerefMut};

pub struct Mutex<T>
{
    acquired: AtomicBool,
    owner: AtomicUsize,
    lock_attempts: AtomicUsize,
    lock_count: AtomicUsize,
    release_count: AtomicUsize,
    regain_count: AtomicUsize,
    content: UnsafeCell<T>,
}

/* Mutex uses the same API as std's Mutex. Create a Mutex using new() and then
   call lock() to block until lock successfully acquired. Drop the lock to release
   it. Use try_lock() to make one attempt at acquiring the lock */

impl<T> Mutex<T>
{
    pub fn new(data: T) -> Mutex<T>
    {
        Mutex
        {
            acquired: AtomicBool::new(false),
            owner: AtomicUsize::new(0),
            lock_attempts: AtomicUsize::new(0),
            lock_count: AtomicUsize::new(0),
            release_count: AtomicUsize::new(0),
            regain_count: AtomicUsize::new(0),
            content: UnsafeCell::new(data),
        }
    }

    pub fn lock(&self) -> MutexGuard<'_, T>
    {
        /* id 0 is no owner, so shift up IDs by one */
        let id = super::pcore::PhysicalCore::get_id() + 1;

        /* spin trying to set acquired to true to obtain the mutex */
        loop
        {
            self.lock_attempts.fetch_add(1, Ordering::Relaxed);

            if self.acquired.compare_exchange(false, true, Ordering::Acquire, Ordering::Relaxed) == Ok(false)
            {
                /* available locks should not have a non-zero owner */
                if self.owner.load(Ordering::SeqCst) != 0
                {
                    hvdebug!("BUG: Lock {:p} was available yet owned by {}", &self, self.owner.load(Ordering::SeqCst));
                }

                /* we've acquired the lock. store our ownership in it */
                self.owner.store(id, Ordering::SeqCst);
                self.lock_count.fetch_add(1, Ordering::Relaxed);
                break;
            }

            /* couldn't acquire lock.. but it's not ours, is it? */
            if self.owner.load(Ordering::SeqCst) == id
            {
                /* we own this lock -- ensure it remains locked for us */
                self.acquired.store(true, Ordering::SeqCst);
                self.regain_count.fetch_add(1, Ordering::Relaxed);
                break;
            }
        }

        MutexGuard { mutex: &self }
    }
    
    /* return true if the lock is held, or false if not */
    pub fn is_locked(&self) -> bool
    {
        self.acquired.load(Ordering::SeqCst)
    }

    /* release the lock */
    fn unlock(&self)
    {
        self.owner.store(0, Ordering::SeqCst);
        self.release_count.fetch_add(1, Ordering::Relaxed);
        self.acquired.store(false, Ordering::Release);
    }
}

/* pretty print a mutex's stats */
impl<T> core::fmt::Debug for Mutex<T>
{
    fn fmt(&self, f: &mut core::fmt::Formatter) -> core::fmt::Result
    {
        write!(f, "{:p}: {} lock attempts, locked {}, released {}, regained lock {} times", &self,
            self.lock_attempts.load(Ordering::Relaxed),
            self.lock_count.load(Ordering::Relaxed),
            self.release_count.load(Ordering::Relaxed),
            self.regain_count.load(Ordering::Relaxed))
    }
}

pub struct MutexGuard<'a, T>
{
    mutex: &'a Mutex<T>,
}

impl<T> Deref for MutexGuard<'_, T>
{
    type Target = T;

    fn deref(&self) -> &Self::Target
    {
        unsafe { &*self.mutex.content.get() }
    }
}

impl<T> DerefMut for MutexGuard<'_, T>
{
    fn deref_mut(&mut self) -> &mut Self::Target
    {
        unsafe { &mut *self.mutex.content.get() }
    }
}

impl<T> Drop for MutexGuard<'_, T>
{
    fn drop(&mut self)
    {
        self.mutex.unlock()
    }
}

/* keep rustc happy */
unsafe impl<T> Send for Mutex<T> where T: Send {}
unsafe impl<T> Sync for Mutex<T> where T: Send {}
unsafe impl<T> Send for MutexGuard<'_, T> where T: Send {}
unsafe impl<T> Sync for MutexGuard<'_, T> where T: Send + Sync {}
