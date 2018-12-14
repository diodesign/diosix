/* diosix machine kernel's locking primitives
 *
 * Provided because, at time of writing, these were not available in no-std RV32 Rust
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

pub struct Spinlock
{
    pub value: usize
}

/* very basic spin lock */
impl Spinlock
{
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