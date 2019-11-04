/* diosix abstracted hardware manager
 *
 * (c) Chris Williams, 2019.
 *
 * See LICENSE for usage and copying.
 */

use spin::Mutex;
use hashbrown::HashMap;
use platform::devices::{self, DeviceType, Device, DeviceReturnData};
use super::physmem::{self, Region, RegionState};
use super::error::Cause;

lazy_static!
{
    /* acquire HARDWARE lock before accessing any system hardware objects */
    static ref HARDWARE: Mutex<HashMap<DeviceType, Device>> = Mutex::new(HashMap::new());
}

/* parse_and_init
   Parse a device tree structure and create a table of devices we can refer to.
   also initialize any of the registered devices so they can be used.
   => device_tree_buf = pointer to device tree in physical memory
   <= return Ok for success, or error code on failure
*/
pub fn parse_and_init(device_tree_buf: &u8) -> Result<(), Cause>
{
    hvlog!("Registering basic abstracted hardware...");
    for (dev_type, dev) in devices::enumerate(device_tree_buf)
    {
        hvlog!("--> {:?}: {:?}", &dev_type, &dev);

        /* perform any high-level initialization */
        match &dev
        {
            /* add available RAM areas to the regions list */
            Device::PhysicalRAM(areas) => for area in areas
            {
                let new_region = Region::new(area.base, area.size, RegionState::Free);
                physmem::add_region(new_region);
            },
            _ => ()
        };

        HARDWARE.lock().insert(dev_type, dev);
    }

    Ok(())
}

/* Lookup a device structure for a registered peripheral by device type
   and execute a function to access it. we take this approach to avoid copying
   data, and to avoid race conditions: while the HARDWARE lock is held, the
   function can safely access the device. 
   => dev_type = type of device to locate
      operation = function or closure to execute to access the requested device
   <= return data from function, or None if unable to find device 
*/
pub fn access(dev_type: DeviceType, operation: impl Fn(&Device) -> DeviceReturnData) -> Option<DeviceReturnData>
{
    /* ensure we hold the lock until the end of the function */
    let locked = HARDWARE.lock();

    let device = locked.get(&dev_type);
    match device
    {
        Some(d) => Some(operation(d)),
        None => None
    }
}
