/* diosix locking primitives
 *  
 * (c) Chris Williams, 2018.
 *
 * See LICENSE for usage and copying.
 */

use core::cell::UnsafeCell;

/* platform library to implement this */
extern "C" {
    fn platform_acquire_spin_lock(lock_var: &usize);
    fn platform_release_spin_lock(lock_var: &usize);
}

/* create an unlocked spinlock */
#[macro_export]
macro_rules! kspinlock
{
    () => (Spinlock { value: 0 });
}

pub struct Spinlock
{
    /* lock value: 0 = unlocked, anything else is locked */
    pub value: usize
}

/* very basic spin lock - use sparingly. prefer Mutex for locking structs */
impl Spinlock
{
    /* create a new spinlock */
    pub fn new() -> Spinlock
    {
        Spinlock { value: 0 }
    }

    /* execute the given closure as a critical section protected by the lock */
    pub fn execute(&self, f: impl Fn())
    {
        self.aquire();
        f();
        self.release();
    }

    /* acquire the lock, or block until successful */
    pub fn aquire(&self)
    {
        unsafe { platform_acquire_spin_lock(&(self.value)); }
    }

    /* release the lock */
    pub fn release(&self)
    {
        unsafe { platform_release_spin_lock(&(self.value)); }
    }
}

/* Use this to ensure a struct is only accessed exclusively. not to be used
on high-contention data. it's first come, first served with no guaranteeded acquisition */
pub struct Mutex<T: ?Sized>
{
    spinlock: Spinlock,
    contents: UnsafeCell<T>
}

/* this is what youu'll use to access the locked data */
pub struct MutexGuard<'a, T: ?Sized + 'a>
{
    spinlock: &'a Spinlock,
    contents: &'a mut T,
}

impl<T> Mutex<T>
{
    pub const fn new(contents: T) -> Mutex<T>
    {
        Mutex
        {
            spinlock: kspinlock!(),
            contents: UnsafeCell::new(contents)
        }
    }

    /* lock the structure so no one else can use it, and then return references
    so we can access/modify its contents */
    pub fn lock(&self) -> MutexGuard<T>
    {
        unsafe { platform_acquire_spin_lock(&(self.spinlock.value)); }
        MutexGuard
        {
            spinlock: &self.spinlock,
            contents: unsafe { &mut *self.contents.get() },
        }
    }
}

/* handle destruction of the mutex by unlocking it */
impl<'a, T: ?Sized> Drop for MutexGuard<'a, T>
{
    fn drop(&mut self)
    {
        unsafe { platform_release_spin_lock(&(self.spinlock.value)); }
    }
}
