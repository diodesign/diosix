/* diosix scheduler timer control
 *
 * (c) Chris Williams, 2018.
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
    unsafe { platform_timer_target(0); }
    /* and throw the switch... */
    unsafe { platform_timer_irq_enable(); }
}
