/* diosix machine kernel's CPU core management
 *
 * (c) Chris Williams, 2018.
 *
 * See LICENSE for usage and copying.
 */

use heap;

/* require some help from the underlying platform */
extern "C"
{
    fn platform_cpu_private_variables() -> *mut Core;
}

/* set to true to unblock SMP cores and allow them to initialize */
static mut SMP_GREEN_LIGHT: bool = false;

/* describe a CPU core - this structure is stored in the per-CPU private variable space */
#[repr(C)]
pub struct Core
{
    pub heap: heap::Heap,
}

impl Core
{
    /* intiialize a CPU core. Prepare it for running supervisor code.
    blocks until cleared to continue by the boot CPU */
    pub fn init()
    {
        /* block until the boot CPU has given us the green light to continue.
        this is unsafe because we're reading without any locking. however,
        there is only one writer (the boot CPU) and multiple readers,
        so there is no data race issue. assumes aligned writes are atomic */
        while !unsafe { SMP_GREEN_LIGHT } { keep_me!(); /* don't optimize away this loop */ }

        /* assume the startup code has allocated space for per-CPU core variables.
        this function returns a pointer to that structure */
        let cpu = Core::this();

        /* initialize private heap */
        unsafe { (*cpu).heap.init(); }
    }

    /* return pointer to the calling CPU core's fixed private data structure */
    pub fn this() -> *mut Core { return unsafe { platform_cpu_private_variables() } }
}

/* only the boot CPU should call this: give waiting SMP cores the green light */
pub fn unblock_smp() { unsafe { SMP_GREEN_LIGHT = true; } }

