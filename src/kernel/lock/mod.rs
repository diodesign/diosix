/* diosix locking primitives
 *  
 * (c) Chris Williams, 2018.
 *
 * See LICENSE for usage and copying.
 */

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

/* very basic spin lock */
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
    fn aquire(&self)
    {
        unsafe { platform_acquire_spin_lock(&(self.value)); }
    }

    /* release the lock */
    fn release(&self)
    {
        unsafe { platform_release_spin_lock(&(self.value)); }
    }
}
