/* diosix RV32 CPU core management
 *
 * (c) Chris Williams, 2018.
 *
 * See LICENSE for usage and copying.
 */

use devicetree;

static mut CPU_CORE_COUNT: Option<usize> = None;

/* initialize CPU handling code
   => device_tree_buf = device tree to parse 
   <= number of CPU cores in tree, or None for parse error */
pub fn init(device_tree_buf: &u8) -> Option<usize>
{
    match devicetree::get_cpu_count(device_tree_buf)
    {
        Some(c) =>
        {
            unsafe { CPU_CORE_COUNT = Some(c) };
            return Some(c);
        }
        None => return None
    }
}

/* return number of CPU cores present in the system,
or None for CPU cores not yet counted. */
pub fn nr_of_cores() -> Option<usize>
{
    return unsafe { CPU_CORE_COUNT };
}
