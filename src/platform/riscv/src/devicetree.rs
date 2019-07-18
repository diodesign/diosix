/* diosix device-tree parser for RV32 and RV64 targets
 *
 * (c) Chris Williams, 2019.
 *
 * See LICENSE for usage and copying.
 */

extern crate hermit_dtb;

use crate::physmem::RAMArea;

/* get_ram_area
   Get the system RAM area's base address and size in bytes. Assumes there is a single RAM block.
   => device_tree_buf = pointer to device tree in hypervisor-accessible RAM
   <= number of bytes in system memory, or None for failure
*/
pub fn get_ram_area(device_tree_buf: &u8) -> Option<RAMArea>
{
    let dev_tree = match unsafe { hermit_dtb::Dtb::from_raw(device_tree_buf) }
    {
        Some(x) => x,
        None => return None,
    };

    let mem_params = match dev_tree.get_property("/memory", "reg")
    {
        Some(x) => x,
        None => return None,
    };

    /* reconstruct memory size from bytes in the DT array. the format is:
    bytes  contents
    0-3    DRAM base address (upper 32 bits)
    4-7    DRAM base address (lower 32 bits)
    8-11   DRAM size (upper 32 bits)
    12-15  DRAM size (lower 32 bits) */
    let mem_base = ((mem_params[7] as u64) << 0
        | (mem_params[6] as u64) << 8
        | (mem_params[5] as u64) << 16
        | (mem_params[4] as u64) << 24
        | (mem_params[3] as u64) << 32
        | (mem_params[2] as u64) << 40
        | (mem_params[1] as u64) << 48
        | (mem_params[0] as u64) << 56) as usize;

    let mem_size = ((mem_params[15] as u64) << 0
        | (mem_params[14] as u64) << 8
        | (mem_params[13] as u64) << 16
        | (mem_params[12] as u64) << 24
        | (mem_params[11] as u64) << 32
        | (mem_params[10] as u64) << 40
        | (mem_params[9] as u64) << 48
        | (mem_params[8] as u64) << 56) as usize;

    return Some(RAMArea
    {
        base: mem_base,
        size: mem_size
    });
}

/* get_cpu_count
   => device_tree_buf = pointer to device tree in hypervisor-accessible RAM
   <= number of CPU cores in system, or None for failure
*/
pub fn get_cpu_count(device_tree_buf: &u8) -> Option<usize>
{
    let dev_tree = match unsafe { hermit_dtb::Dtb::from_raw(device_tree_buf) }
    {
        Some(x) => x,
        None => return None,
    };

    let mut cpus = 0;
    for node in dev_tree.enum_subnodes("/cpus")
    {
        if node.starts_with("cpu@")
        {
            cpus = cpus + 1;
        }
    }

    return Some(cpus);
}

/* get the builtin CPU timer's frequency, which is fixed in hardware
   => device_tree_buf = pointer to device tree in hypervisor-accessible RAM
   <= timer frequency, or None for failure
*/
pub fn get_timebase_freq(device_tree_buf: &u8) -> Option<usize>
{
    let dev_tree = match unsafe { hermit_dtb::Dtb::from_raw(device_tree_buf) }
    {
        Some(x) => x,
        None => return None,
    };

    let freq = match dev_tree.get_property("/cpus", "timebase-frequency")
    {
        Some(f) => (f[0] as u32) | ((f[1] as u32) << 8) | ((f[2] as u32) << 16) | ((f[3] as u32) << 24),
        None => return None,
    };

    return Some(freq as usize);
}

/* get base address of the MMIO serial port */
pub fn get_uart_base(device_tree_buf: &u8) -> Option<usize>
{
    let dev_tree = match unsafe { hermit_dtb::Dtb::from_raw(device_tree_buf) }
    {
        Some(x) => x,
        None => return None,
    };

    let uart = match dev_tree.get_property("/uart", "reg")
    {
        Some(x) => x,
        None => return None,
    };
    let uart_base = ((uart[7] as u64) << 0
        | (uart[6] as u64) << 8
        | (uart[5] as u64) << 16
        | (uart[4] as u64) << 24
        | (uart[3] as u64) << 32
        | (uart[2] as u64) << 40
        | (uart[1] as u64) << 48
        | (uart[0] as u64) << 56) as usize;

    return Some(uart_base);
}