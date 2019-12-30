/* diosix abstracted hardware manager
 *
 * (c) Chris Williams, 2019.
 *
 * See LICENSE for usage and copying.
 */

use spin::Mutex;
use devicetree;
use platform::devices::Devices;
use platform::physmem::RAMAreaIter;
use super::error::Cause;
use super::pcore;

lazy_static!
{
    /* acquire HARDWARE lock before accessing any system hardware */
    static ref HARDWARE: Mutex<Option<Devices>> = Mutex::new(None);

    /* we might end up in a situation where a CPU core holds HARDWARE
    but was interrupted or otherwise reentered. keep a track of the owner
    of HARDWARE so that it can unlock the structure if needed */
    static ref OWNER: Mutex<pcore::PhysicalCoreID> = Mutex::new(pcore::PhysicalCore::get_id());
}

/* parse_and_init
   Parse a device tree structure to create a base set of hardware devices.
   also initialize the devices so they can be used.
   => device_tree = pointer to device tree in physical memory
   <= return Ok for success, or error code on failure
*/
pub fn parse_and_init(dtb: &devicetree::DeviceTreeBlob) -> Result<(), Cause>
{
    match Devices::new(dtb)
    {
        Some(d) =>
        {
            hvdebug!("Discovered hardware:\n{:?}", d);
            *(HARDWARE.lock()) = Some(d);
        },
        None => return Err(Cause::DeviceTreeBad)
    };
    return Ok(())
}

#[derive(Copy, Clone)]
enum LockAttempts
{
    Once,
    Multiple
}

/* acquire a lock on HARDWARE. If this CPU core is supposed to be
   holding it already, then bust the lock so that it and others can
   access it again. See notes above for OWNER.
   => attempts = try just Once or Multiple times to acquire lock
   <= Some MutexGuard containing the device structure, or None for unsuccessful */
fn acquire_hardware_lock(attempts: LockAttempts) -> Option<spin::MutexGuard<'static, core::option::Option<platform::devices::Devices>>>
{
    loop
    {
        let mut owner = OWNER.lock();
        if *owner == pcore::PhysicalCore::get_id()
        {
            /* we apparently own HARDWARE already so acquire, or force unlock it and
            acquire it again */
            match HARDWARE.try_lock()
            {
                Some(hw) => return Some(hw),
                None =>
                {
                    unsafe { HARDWARE.force_unlock(); }
                }
            };
        }
        else
        {
            /* we don't own HARDWARE so acquire: try once or multiple times
            depending on attempts parameter */
            match (HARDWARE.try_lock(), attempts)
            {
                (Some(hw), _) =>
                {
                    *owner = pcore::PhysicalCore::get_id();
                    return Some(hw);
                },
                (None, LockAttempts::Once) => return None,
                (None, LockAttempts::Multiple) => ()
            }
        }
    }
}

/* routines to interact with the system's base devices */

/* write the string msg out to the debug logging console.
   if the system is busy then return immediately, don't block. 
   <= true if able to write, false if not */
pub fn write_debug_string(msg: &str) -> bool
{
    let hw = acquire_hardware_lock(LockAttempts::Once);
    if hw.is_none() == true
    {
        return false;
    }

    match &*(hw.unwrap())
    {
        Some(d) =>
        {
            d.write_debug_string(msg);
            true
        },
        None => false
    }
}

/* return an iterator for the physical RAM areas we can use for any purpose,
or None if we can't read the available memory */
pub fn get_phys_ram_areas() -> Option<RAMAreaIter>
{
    match &*(acquire_hardware_lock(LockAttempts::Multiple).unwrap())
    {
        Some(d) => Some(d.get_phys_ram_areas()),
        None => None
    }
}

/* for this CPU core, enable scheduler timer interrupt and find a workload to run */
pub fn scheduler_timer_start()
{
    match &*(acquire_hardware_lock(LockAttempts::Multiple).unwrap())
    {
        Some(d) => d.scheduler_timer_start(),
        None => ()
    };
}

/* tell the scheduler to interrupt this core in usecs microseconds */
pub fn scheduler_timer_next(usecs: u64)
{
    match &*(acquire_hardware_lock(LockAttempts::Multiple).unwrap())
    {
        Some(d) => d.scheduler_timer_next(usecs),
        None => ()
    };
}
