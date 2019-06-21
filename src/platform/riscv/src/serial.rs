/* diosix RV32G/RV64G hardware serial controller
 *
 * (c) Chris Williams, 2019.
 *
 * See LICENSE for usage and copying.
 */

use devicetree;

/* initialize timer for preemptive scheduler */ 
pub fn init(device_tree_buf: &u8) -> Option<usize>
{
    devicetree::get_uart_base(device_tree_buf)
}
