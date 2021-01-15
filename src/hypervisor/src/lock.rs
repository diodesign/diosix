/* diosix high-level hypervisor's locking primitives
 *
 * Provides a standard spin lock and a mutex
 * 
 * The mutex is reentrant, which means when a physical
 * core holds a mutex and then tries to acquire it
 * again, this operation will succeed.
 * 
 * this is so that, eg, if a core holds a mutex
 * and is interrupted, it can regain access
 * to the locked data, use it, and release it.
 * 
 * use lock() to acquire a mutex.
 * it is unlocked when it goes out of scope.
 * the mutex also maintains accounting stats
 * and is named to aid debugging.
 * 
 * (c) Chris Williams, 2021.
 *
 * See LICENSE for usage and copying.
 */

use core::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use core::cell::UnsafeCell;
use core::ops::{Deref, DerefMut};
use super::pcore::PhysicalCore;

/* if a lock() call spins more than DEADLOCK_THRESHOLD times
   then it's considered a deadlocked mutex */
const DEADLOCK_THRESHOLD: usize = 1000000;

/* define a snip lock primitive */
pub struct SpinLock
{
    lock: AtomicBool
}

impl SpinLock
{
    pub fn new() -> SpinLock
    {
        SpinLock { lock: AtomicBool::new(false) }
    }

    /* spin until the lock value == must_equal, and then atomically do lock value = new_value */
    fn spin(&self, must_equal: bool, new_value: bool)
    {
        loop
        {
            if self.lock.compare_exchange(must_equal, new_value, Ordering::Acquire, Ordering::Relaxed) == Ok(must_equal)
            {
                return;
            }
        }   
    }
    
    /* acquire the lock, and block until successful */
    pub fn lock(&self)
    {
        self.spin(false, true);
    }

    /* release the lock */
    pub fn unlock(&self)
    {
        self.spin(true, false);   
    }
}

pub struct Mutex<T>
{
    /* the data we're protecting */
    content: UnsafeCell<T>,

    /* owner_lock protects owned and owner.
       if the owned is false, then the mutex is considered free.
       if the owned is true, the mutex is considered held by a physical core whose ID == owner */
    owner_lock: SpinLock,
    owned: AtomicBool,
    owner: AtomicUsize,

    /* accounting */
    lock_attempts: AtomicUsize,
    lock_count: AtomicUsize,
    description: &'static str
}

/* Mutex uses the same API as std's Mutex. Create a Mutex using new() and then
   call lock() to block until mutex successfully acquired. Drop the mutex to release */
impl<T> Mutex<T>
{
    pub fn new(description: &'static str, data: T) -> Mutex<T>
    {
        Mutex
        {
            content: UnsafeCell::new(data),
            owner_lock: SpinLock::new(),
            owned: AtomicBool::new(false),
            owner: AtomicUsize::new(0),
            lock_attempts: AtomicUsize::new(0),
            lock_count: AtomicUsize::new(0),
            description
        }
    }

    /* spin until ready to return reference to protected data */
    pub fn lock(&self) -> MutexGuard<'_, T>
    {
        let mut attempts = 0;

        let this_pcore_id = PhysicalCore::get_id();
        loop
        {
            /* hold the spin lock while checking the metadata */
            self.owner_lock.lock();
            self.lock_attempts.fetch_add(1, Ordering::Relaxed);
            attempts = attempts + 1;
            if attempts == DEADLOCK_THRESHOLD
            {
                hvdebug!("BUG: {} mutex ({:p}) may be deadlocked", self.description, &self.content);
            }

            /* determine if the mutex is available, or may even
               already be held by this physical core */
            if self.owned.load(Ordering::SeqCst) == false
            {
                /* lock is available so claim it */
                self.owned.store(true, Ordering::SeqCst);
                self.owner.store(this_pcore_id, Ordering::SeqCst);
                break;
            }
            else
            {
                /* mutex is already held though this pcore may own it anyway */
                if self.owner.load(Ordering::SeqCst) == this_pcore_id
                {
                    break;
                }
            }

            /* give another core a chance to acquire the mutex */
            self.owner_lock.unlock();
        }

        /* don't forget to unlock the metadata
           before returning a reference to the content */
        self.lock_count.fetch_add(1, Ordering::Relaxed);
        self.owner_lock.unlock();
        MutexGuard { mutex: &self }
    }

    /* unlock the mutex */
    fn unlock(&self)
    {
        self.owner_lock.lock();
        self.owned.store(false, Ordering::SeqCst);
        self.owner_lock.unlock();
    }

    /* return true if the mutex is locked, or false if not */
    pub fn is_locked(&self) -> bool
    {
        self.owner_lock.lock();
        let locked = self.owned.load(Ordering::SeqCst);
        self.owner_lock.unlock();
        locked
    }
}

/* pretty print a mutex's stats */
impl<T> core::fmt::Debug for MutexGuard<'_, T>
{
    fn fmt(&self, f: &mut core::fmt::Formatter) -> core::fmt::Result
    {
        write!(f, "{} attempts to acquire {}, {} succeeded",
            self.mutex.lock_attempts.load(Ordering::Relaxed),
            self.mutex.description,
            self.mutex.lock_count.load(Ordering::Relaxed))
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
