/* SiFive U34 hardware-specific code
 *
 * (c) Chris Williams, 2018.
 *
 * See LICENSE for usage and copying.
 */

#![no_std]
extern crate hermit_dtb;

/* get_ram_size
   => device_tree_buf = pointer to device tree in kernel-accessible RAM
   <= number of bytes in system memory, or None for failure
*/
pub fn get_ram_size(device_tree_buf: &u8) -> Option<usize>
{
  let dev_tree = match unsafe { hermit_dtb::Dtb::from_raw(device_tree_buf) }
  {
    Some(x) => x,
    None => return None
  };

  let mem_params = match dev_tree.get_property("/memory@80000000", "reg")
  {
    Some(x) => x,
    None => return None
  };

  /* reconstruct memory params from bytes */
  let mem_size = (mem_params[15] as usize) << 0  |
                 (mem_params[14] as usize) << 8  |
                 (mem_params[13] as usize) << 16 |
                 (mem_params[12] as usize) << 24;
  return Some(mem_size);
}
