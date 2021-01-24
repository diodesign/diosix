/* diosix abstracted hardware manager
 *
 * (c) Chris Williams, 2019-2021.
 *
 * See LICENSE for usage and copying.
 */

use alloc::vec::Vec;
use super::lock::Mutex;
use platform::devices::Devices;
use platform::physmem::{PhysMemBase, PhysMemSize};
use platform::timer;
use super::error::Cause;

lazy_static!
{
    /* acquire HARDWARE before accessing any system hardware */
    static ref HARDWARE: Mutex<Option<Devices>> = Mutex::new("hardware management", None);
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

/* routines to interact with the system's base devices */

/* write the string msg out to the debug logging console.
   if the system is busy, return
   => msg = string to write out (not necessarily zero term'd)
   <= true if able to write, false if not */
pub fn write_debug_string(msg: &str) -> bool
{
    /* avoid blocking if we can */
    if HARDWARE.is_locked() == true
    {
        return false;
    }

    match &*(HARDWARE.lock())
    {
        Some(d) =>
        {
            d.write_debug_string(msg);
            true
        },
        None => false
    }
}

/* read a single character from the debuging console, or None if none.
   this does not block */
pub fn read_debug_char() -> Option<char>
{
    /* avoid blocking on a lock if we can */
    if HARDWARE.is_locked() == true
    {
        return None;
    }

    match &*(HARDWARE.lock())
    {
        Some(d) => d.read_debug_char(),
        None => None
    }   
}

/* return number of discovered logical CPU cores, or None if value unavailable */
pub fn get_nr_cpu_cores() -> Option<usize>
{
    match &*(HARDWARE.lock())
    {
        Some(d) => Some(d.get_nr_cpu_cores()),
        None => None
    }
}

/* return a list of the physical RAM chunks present in the system,
or None if we can't read the available memory */
pub fn get_phys_ram_chunks() -> Option<Vec<platform::physmem::RAMArea>>
{
    match &*(HARDWARE.lock())
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
    match &*(HARDWARE.lock())
    {
        Some(d) => d.scheduler_timer_start(),
        None => ()
    };
}

/* tell the scheduler to interrupt this core
when duration number of timer ticks or sub-seconds passes */
pub fn scheduler_timer_next_in(duration: timer::TimerValue)
{
    match &*(HARDWARE.lock())
    {
        Some(d) => d.scheduler_timer_next_in(duration),
        None => ()
    };
}

/* tell the scheduler to interrupt this core when the system clock equals
target value in ticks or sub-seconds as its current value */
pub fn scheduler_timer_at(target: timer::TimerValue)
{
    match &*(HARDWARE.lock())
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
    match &*(HARDWARE.lock())
    {
        Some(d) => d.scheduler_get_timer_next_at(),
        None => None
    }
}

/* get the CPU's timer frequency in Hz */
pub fn scheduler_get_timer_frequency() -> Option<u64>
{
    match &*(HARDWARE.lock())
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
    match &*(HARDWARE.lock())
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
    match &*(HARDWARE.lock())
    {
        Some(d) => match d.spawn_virtual_environment(cpus, boot_cpu_id, mem_base, mem_size)
        {
            Some(v) => return Ok(v),
            None => return Err(Cause::DeviceTreeBad)
        },
        None => Err(Cause::CantCloneDevices)
    }
}