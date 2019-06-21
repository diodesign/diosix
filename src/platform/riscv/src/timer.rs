/* diosix RV32G/RV64G hardware timer control for scheduler
 *
 * (c) Chris Williams, 2019.
 *
 * See LICENSE for usage and copying.
 */

use devicetree;

extern "C"
{
    fn platform_timer_target(target: u64);
    fn platform_timer_irq_enable();
    fn platform_timer_now() -> u64;
}

/* write once during init, read-only after */
static mut CPU_TIMER_FREQ: usize = 0;

/* initialize timer for preemptive scheduler */ 
pub fn init(device_tree_buf: &u8) -> bool
{
    match devicetree::get_timebase_freq(device_tree_buf)
    {
        Some(f) =>
        {
            unsafe { CPU_TIMER_FREQ = f; }
            return true;
        },
        None => return false
    }
}

/* enable per-CPU core incremental timer interrupt */
pub fn start()
{
    /* zero means trigger timer right away */
    next(0);
    /* and throw the switch... */
    unsafe { platform_timer_irq_enable(); }
}

/* return the current incremental timer value */
pub fn now() -> u64
{
    unsafe { platform_timer_now() }
}

/* set the new timer interrupt target value */
pub fn next(target: u64)
{
    unsafe { platform_timer_target(target); }
}
