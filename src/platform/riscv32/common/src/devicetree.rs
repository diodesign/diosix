/* RISC-V 32-bit device-tree hardware-specific code fpr
 *
 * (c) Chris Williams, 2018.
 *
 * See LICENSE for usage and copying.
 */

extern crate hermit_dtb;

/* get_ram_size
   => device_tree_buf = pointer to device tree in kernel-accessible RAM
   <= number of bytes in system memory, or None for failure
*/
pub fn get_ram_size(device_tree_buf: &u8) -> Option<u64>
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

  /* reconstruct memory params from bytes in the DT array. the format is:
     bytes  contents
     0-3    DRAM base address (upper 32 bits)
     4-7    DRAM base address (lower 32 bits)
     8-11   DRAM size (upper 32 bits)
     12-15  DRAM size (lower 32 bits) */
  let mem_size =  (mem_params[15] as u64) << 0  |
                  (mem_params[14] as u64) << 8  |
                  (mem_params[13] as u64) << 16 |
                  (mem_params[12] as u64) << 24 |
                  (mem_params[11] as u64) << 32 |
                  (mem_params[10] as u64) << 40 |
                  (mem_params[ 9] as u64) << 48 |
                  (mem_params[ 8] as u64) << 56;
  return Some(mem_size);
}
