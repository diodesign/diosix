/* diosix abstracted hardware manager
 *
 * (c) Chris Williams, 2019-2021.
 *
 * See LICENSE for usage and copying.
 */

use alloc::vec::Vec;
use spin::Mutex;
use platform::devices::Devices;
use platform::physmem::{PhysMemBase, PhysMemSize};
use platform::timer;
use super::error::Cause;
use super::pcore;

lazy_static!
{
    /* acquire HARDWARE before accessing any system hardware */
    static ref HARDWARE: Mutex<Option<Devices>> = Mutex::new(None);

    /* ID of the physical core that last obtained the HARDWARE lock */
    static ref HARDWARE_PREV_OWNER: Mutex<Option<pcore::PhysicalCoreID>> = Mutex::new(None);
}

/* parse_and_init
   Parse a device tree structure to create a base set of hardware devices.
   also initialize the devices so they can be used.
   call before using acquire_hardware_lock() to access HARDWARE.
   => device_tree = byte slice containing the device tree in physical memory
   <= return Ok for success, or error code on failure
*/
pub fn parse_and_init(dtb: &[u8]) -> Result<(), Cause>
{
    if let Ok(dt) = Devices::new(dtb)
    {
        *(HARDWARE.lock()) = Some(dt);
        return Ok(())
    }
    else
    {
        return Err(Cause::DeviceTreeBad);
    }
}

#[derive(Copy, Clone)]
enum LockAttempts
{
    Once,
    Multiple
}

/* acquire a lock on HARDWARE. If this physical CPU core is supposed to be
   holding it already, then bust the lock so that it and others can
   access it again. Use this function to safely access HARDWARE.
   => attempts = try just Once or Multiple times to acquire lock
   <= Some MutexGuard containing the device structure, or None for unsuccessful */
fn acquire_hardware_lock(attempts_allowed: LockAttempts) -> Option<spin::MutexGuard<'static, Option<platform::devices::Devices>>>
{
    loop
    {
        /* set to true if an attempt was made no matter how successful */
        let mut attempt = false;

        match HARDWARE.try_lock()
        {
            /* successfully obtained the hardware lock though we're racing
            the None branch so don't assume we'll get HARDWARE_PREV_OWNER */
            Some(lock) =>
            {
                /* try to get the HARDWARE_PREV_OWNER lock, too, or fail out */
                if let Some(mut owner_lock) = HARDWARE_PREV_OWNER.try_lock()
                {
                    /* we own HARDWARE and HARDWARE_PREV_OWNER so safe to say,
                    we can slap our ID on the owner and return the unlocked HARDWARE contents */
                    *owner_lock = Some(pcore::PhysicalCore::get_id());
                    return Some(lock);
                }

                /* this counts as an attempt */
                attempt = true;
            },

            /* couldn't obtain the hardware lock, so decide whether
            we rightfully own this lock, or need to wait for it to be released */
            None =>
            {
                match HARDWARE_PREV_OWNER.try_lock()
                {
                    /* we couldn't get HARDWARE but we did get HARDWARE_PREV_OWNER */
                    Some(owner_lock) => match *owner_lock
                    {
                        /* are we supposed to own HARDWARE? */
                        Some(owner) => if owner == pcore::PhysicalCore::get_id()
                        {
                            /* we own this HARDWARE lock -- probably held across an IRQ/exception --
                            so reclaim it while we still hold HARDWARE_PREV_OWNER */
                            unsafe { HARDWARE.force_unlock(); }
                            return Some(HARDWARE.lock());
                        },

                        /* not obtaining the hardware nor owner lock counts as an attempt */
                        None => attempt = true
                    },

                    /* failing to get the previous owner counts as an attempt */
                    None => attempt = true
                }
            }
        }

        match attempts_allowed
        {
            LockAttempts::Once => if attempt == true
            {
                /* one strike and you're out */
                return None;
            },
            LockAttempts::Multiple => ()
        }
    }
}

/* routines to interact with the system's base devices */

/* write the string msg out to the debug logging console.
   if the system is busy then return immediately, don't block.
   => msg = string to write out
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

/* return number of discovered logical CPU cores, or None if value unavailable */
pub fn get_nr_cpu_cores() -> Option<usize>
{
    match &*(acquire_hardware_lock(LockAttempts::Multiple).unwrap())
    {
        Some(d) => Some(d.get_nr_cpu_cores()),
        None => None
    }
}

/* return a list of the physical RAM chunks present in the system,
or None if we can't read the available memory */
pub fn get_phys_ram_chunks() -> Option<Vec<platform::physmem::RAMArea>>
{
    match &*(acquire_hardware_lock(LockAttempts::Multiple).unwrap())
    {
        Some(d) => Some(d.get_phys_ram_areas()),
        None => None
    }
}

/* return total amount of physical RAM present in the system */
pub fn get_phys_ram_total() -> Option<usize>
{
    if let Some(areas) = get_phys_ram_chunks()
    {
        let mut total = 0;
        for area in areas
        {
            total = total + area.size;
        }

        return Some(total);
    }

    None
}

/* for this CPU core, enable scheduler timer interrupt */
pub fn scheduler_timer_start()
{
    match &*(acquire_hardware_lock(LockAttempts::Multiple).unwrap())
    {
        Some(d) => d.scheduler_timer_start(),
        None => ()
    };
}

/* tell the scheduler to interrupt this core
when duration number of timer ticks or sub-seconds passes */
pub fn scheduler_timer_next_in(duration: timer::TimerValue)
{
    match &*(acquire_hardware_lock(LockAttempts::Multiple).unwrap())
    {
        Some(d) => d.scheduler_timer_next_in(duration),
        None => ()
    };
}

/* tell the scheduler to interrupt this core when the system clock equals
target value in ticks or sub-seconds as its current value */
pub fn scheduler_timer_at(target: timer::TimerValue)
{
    match &*(acquire_hardware_lock(LockAttempts::Multiple).unwrap())
    {
        Some(d) => d.scheduler_timer_at(target),
        None => ()
    };
}
    

/* get when the scheduler timer IRQ is next set to fire on this core.
this is a clock-on-the-wall value: it's a number of ticks or
sub-seconds since the timer started, not the duration to the next IRQ */
pub fn scheduler_get_timer_next_at() -> Option<timer::TimerValue>
{
    match &*(acquire_hardware_lock(LockAttempts::Multiple).unwrap())
    {
        Some(d) => d.scheduler_get_timer_next_at(),
        None => None
    }
}

/* get the CPU's timer frequency in Hz */
pub fn scheduler_get_timer_frequency() -> Option<u64>
{
    match &*(acquire_hardware_lock(LockAttempts::Multiple).unwrap())
    {
        Some(d) => d.scheduler_get_timer_frequency(),
        None => None
    }
}

/* return the timer's current value in microseconds, or None for no timer
this is a clock-on-the-wall value in that it always incremements and does
not reset. the underlying platform code can do what it needs to implement this */
pub fn scheduler_get_timer_now() -> Option<timer::TimerValue>
{
    match &*(acquire_hardware_lock(LockAttempts::Multiple).unwrap())
    {
        Some(d) => d.scheduler_get_timer_now(),
        None => None
    }
}

/* clone the system's base device tree blob structure so it can be passed
to guest capsules. the platform code should customize the tree to ensure
peripherals are virtualized. the platform code therefore controls what
hardware is provided. the hypervisor sets how many CPUs and RAM are available.
the rest is decided by the platform code.
   => cpus = number of virtual CPU cores in this capsule
      boot_cpu_id = ID of system's boot CPU (typically 0)
      mem_base = base physical address of the contiguous system RAM
      mem_size = number of bytes available in the system RAM
   <= returns dtb as a byte array, or an error code
*/
pub fn clone_dtb_for_capsule(cpus: usize, boot_cpu_id: u32, mem_base: PhysMemBase, mem_size: PhysMemSize) -> Result<Vec<u8>, Cause>
{
    match &*(acquire_hardware_lock(LockAttempts::Multiple).unwrap())
    {
        Some(d) => match d.spawn_virtual_environment(cpus, boot_cpu_id, mem_base, mem_size)
        {
            Some(v) => return Ok(v),
            None => return Err(Cause::DeviceTreeBad)
        },
        None => Err(Cause::CantCloneDevices)
    }
}