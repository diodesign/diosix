/* Reimplement Rust's AtomicUsize and AtomicBool for non-Arm and non-x86 targets,
 * Right now, for example, RISC-V atomic exchange instructions are missing from
 * Rust nightly's LLVM, so we'll implement them here. As soon as Rust picks up
 * working full atomic support from LLVM, we'll ditch this code and instead use
 * the official sources.
 * 
 * This code calls down to platform code, which must be implemented for the given target.
 * This code also only implements what's needed for lazy static's once and mutex code.
 * ie: new, load, store, and compare_and_swap. load and store are handled by intrinsics,
 * leaving us to implement atomic compare-and-swap.
 *
 * (c) Chris Williams, 2018.
 * See diosix LICENSE for usage and copying
 * 
 * Based on Rust's libcore core::sync::atomic API define here:
 * https://github.com/rust-lang/rust/blob/master/src/libcore/sync/atomic.rs
 * libcore is MIT-licensed: https://github.com/rust-lang/rust/blob/master/LICENSE-MIT
 * 
 */

use core::sync::atomic::Ordering::{self, *};
use core::intrinsics;
use core::cell::UnsafeCell;

extern "C"
{
    fn platform_cpu_wait();
    fn platform_compare_and_swap(ptr: *mut usize, expected: usize, new: usize) -> usize;
    fn platform_aq_compare_and_swap(ptr: *mut usize, expected: usize, new: usize) -> usize;
}

/* do something to avoid optimizing away a loop */
pub fn cpu_relax()
{
    unsafe { platform_cpu_wait() /* NOP */ };
}

/* implement atomic load: fetch from *ptr using given ordering */
unsafe fn atomic_load<T>(ptr: *const T, order: Ordering) -> T
{
    match order
    {
        Acquire => intrinsics::atomic_load_acq(ptr),
        Relaxed => intrinsics::atomic_load_relaxed(ptr),
        SeqCst => intrinsics::atomic_load(ptr),
        _ => panic!("Not possible to atomically load with ordering {:?}", order)
    }
}

/* implement atomic store: write valye to *ptr using given ordering */
unsafe fn atomic_store<T>(ptr: *mut T, value: T, order: Ordering) {
    match order
    {
        Release => intrinsics::atomic_store_rel(ptr, value),
        Relaxed => intrinsics::atomic_store_relaxed(ptr, value),
        SeqCst => intrinsics::atomic_store(ptr, value),
        _ => panic!("Not possible to atomically store with ordering {:?}", order)
    }
}

/* implement atomic compare-and-swap: update *ptr to new value if it contained expected value,
and return the pre-update value. if the pre-update value equals the expected value then the update occurred */
unsafe fn atomic_compare_exchange(ptr: *mut usize, expected: usize, new: usize, order: Ordering) -> usize
{
    match order
    {
        SeqCst => platform_compare_and_swap(ptr, expected, new),
        Acquire => platform_aq_compare_and_swap(ptr, expected, new),
        _ => panic!("Not possible to atomically exchange with ordering {:?}", order)
    }
}

/* ensure we're aligned to a double word boundary to keep all
architectures happy: not every CPU can do non-aligned atomics */
#[derive(Debug)]
#[repr(C, align(8))]
pub struct AtomicBool
{
    /* keeping it usize keeps everything simple and ensures
    we don't try to atomically operate a single byte which
    isn't possible on certain architectures, such as RV32 */
    contents: UnsafeCell<usize>
}

unsafe impl Sync for AtomicBool {}
pub const ATOMIC_BOOL_INIT: AtomicBool = AtomicBool::new(false);

impl AtomicBool
{
    pub const fn new(flag: bool) -> AtomicBool
    {
        AtomicBool { contents: UnsafeCell::new(flag as usize) }
    }

    pub fn load(&self, order: Ordering) -> bool
    {
        unsafe { atomic_load(self.contents.get(), order) != 0 }
    }

    pub fn store(&self, flag: bool, order: Ordering)
    {
        unsafe { atomic_store(self.contents.get(), flag as usize, order) };
    }

    pub fn compare_and_swap(&self, expected: bool, new: bool, order: Ordering) -> bool
    {
        unsafe { atomic_compare_exchange(self.contents.get(), expected as usize, new as usize, order) != 0 }
    }
}

/* AtomicUsize is basically the same as AtomicBool but using usize rather than bool */
#[derive(Debug)]
#[repr(C, align(8))]
pub struct AtomicUsize
{
    contents: UnsafeCell<usize>
}

unsafe impl Sync for AtomicUsize {}

impl AtomicUsize
{
    pub const fn new(value: usize) -> AtomicUsize
    {
        AtomicUsize { contents: UnsafeCell::new(value) }
    }

    pub fn load(&self, order: Ordering) -> usize
    {
        unsafe { atomic_load(self.contents.get(), order) }
    }

    pub fn store(&self, value: usize, order: Ordering)
    {
        unsafe { atomic_store(self.contents.get(), value, order) };
    }

    pub fn compare_and_swap(&self, expected: usize, new: usize, order: Ordering) -> usize
    {
        unsafe { atomic_compare_exchange(self.contents.get(), expected, new, order) }
    }
}
