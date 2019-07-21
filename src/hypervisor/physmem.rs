/* diosix hypervisor physical memory management
 *
 * Allocate/free memory for supervisors
 * 
 * (c) Chris Williams, 2019.
 *
 * See LICENSE for usage and copying.
 */

use platform;
use spin::Mutex;
use error::Cause;
use alloc::collections::linked_list::LinkedList;
use platform::physmem::{PhysMemBase, PhysMemEnd, PhysMemSize, AccessPermissions};

lazy_static!
{
    /* acquire REGIONS lock before accessing any physical RAM regions */
    static ref REGIONS: Mutex<LinkedList<Region>> = Mutex::new(LinkedList::new());
}

/* describe a physical memory region's state */
#[derive(Copy, Clone)]
pub enum RegionState
{
    InUse,  /* allocated to a capsule */
    Free    /* available to allocate to a capsule */
}

/* describe a physical memory region */
#[derive(Copy, Clone)]
pub struct Region
{
    base: PhysMemBase,
    end: PhysMemEnd,
    state: RegionState
}

impl Region
{
    /* allow the currently running supervisor to access this region of physical memory.
       return true for success, or false if request failed */
    pub fn grant_access(&self) -> bool
    {
        match self.state
        {
            RegionState::InUse =>
            {
                platform::physmem::protect(0, self.base, self.end, AccessPermissions::ReadWriteExecute);
                true
            },
            RegionState::Free =>   
            {
                hvalert!("Can't grant access to a non-in-use physical RAM region (base 0x{:x} size {:x})",
                        self.base, self.end - self.base);
                false
            }
        }
    }

    /* return or change attributes */
    pub fn base(&self) -> PhysMemBase { self.base }
    pub fn end(&self) -> PhysMemEnd { self.end }
    pub fn size(&self) -> PhysMemSize { self.end - self.base }
    pub fn increase_base(&mut self, size: PhysMemSize) { self.base = self.base + size; }
}

/* return the physical RAM region covering the entirely of the boot supervisor.
this is to ensure the physical RAM storing the supervisor isn't reallocated */
pub fn boot_supervisor() -> Region
{
    let (base, end) = platform::physmem::boot_supervisor();
    Region { base: base, end: end, state: RegionState::InUse }
}

/* intiialize the hypervisor's physical memory management.
   called once by the boot CPU core.
   => device_tree_buf = pointer to device tree to parse
   <= total number of bytes available, or None for failure
*/
pub fn init(device_tree_buf: &u8) -> Option<PhysMemSize>
{
    /* keep a running total of the number of bytes to play with */
    let mut available_bytes = 0;

    /* gather up all physical RAM areas from which future
    capsule physical RAM allocations will be drawn.
    this list is built from available physical RAM: it must not include
    any RAM areas already in use by the hypervisor, peripherals, etc.
    the undelying platform code needs to exclude those off-limits areas.
    in other words, available_ram() must only return fully usable RAM areas */
    let mut regions = REGIONS.lock();

    match platform::physmem::available_ram(device_tree_buf)
    {
        Some(iter) => for area in iter
        {
            hvlog!("Physical memory area found at 0x{:x}, size: {} bytes ({} MB)", area.base, area.size, area.size >> 20);

            regions.push_front(Region
            {
                base: area.base,
                end: area.base + area.size,
                state: RegionState::Free
            });

            available_bytes = available_bytes + area.size;
        },
        None => return None
    }

    return Some(available_bytes);
}

/* allocate a region of available physical memory for capsule use
   => size = number of bytes in region
   <= Region structure for the space, or an error code */
pub fn alloc_region(size: PhysMemSize) -> Result<Region, Cause>
{
    /* set to Some when we've found a suitable region */
    let mut area: Option<Region> = None;

    /* carve up the available ram for capsules. this approach is a little crude
    but may do for now. it means capsules can't grow */
    let mut regions = REGIONS.lock();
    for region in regions.iter_mut()
    {
        match region.state
        {
            RegionState::Free =>
            {
                if region.size() >= size
                {
                    /* free area is large enough for this requested region.
                    carve out an inuse region from start of free region,
                    and adjust free region's size. */
                    area = Some(Region
                    {
                        base: region.base(),
                        end: region.base() + size,
                        state: RegionState::InUse
                    });
                    region.increase_base(size);
                    break;
                }
            },
            _ => {} /* skip in-use regions */
        }
    }

    /* handle whether we found a suitable area or not */
    match area
    {
        None => return Err(Cause::PhysNotEnoughFreeRAM),
        Some(a) =>
        {
            regions.push_front(a);
            Ok(a) /* return bonds of new region */
        }
    }
}
