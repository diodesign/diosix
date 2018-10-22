/* Qemu Virt 32-bit hardware-specific code
 *
 * (c) Chris Williams, 2018.
 *
 * See LICENSE for usage and copying.
 */

#![no_std]
pub extern crate common;

/* get_ram_size
   Calculate available physical RAM size from given devicetree structure
   => device_tree_buf = pointer to devicetree structure
   <= RAM size in bytes, or None for failure
*/
pub fn get_ram_size(device_tree_buf: &u8) -> Option<u64>
{
  common::devicetree::get_ram_size(device_tree_buf)
}
