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
use alloc::collections::linked_list::LinkedList;
use platform::physmem::{PhysMemBase, PhysMemEnd, PhysMemSize, AccessPermissions};
use super::error::Cause;
use super::hardware;

/* return the physical RAM region covering the entirely of the boot capsule's supervisor */
pub fn boot_supervisor() -> Region
{
    let (base, end) = platform::physmem::boot_supervisor();
    Region { base: base, end: end, state: RegionState::InUse }
}

/* gather up all physical RAM areas from which future capsule physical
RAM allocations will be drawn into the REGIONS list. this list is built from
available physical RAM: it must *not* include any RAM areas already in use by
the hypervisor, boot supervisor image, peripherals, etc. the underlying
platform code needs to exclude those off-limits areas. */
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
    /* create a new region */
    pub fn new(base: PhysMemBase, size: PhysMemSize, state: RegionState) -> Region
    {
        Region
        {
            base: base,
            end: base + size,
            state: state
        }
    }

    /* allow the currently running supervisor kernel to access this region of physical memory.
       only allow access if the region is marked in use. 
       return true for success, or false if request failed */
    pub fn grant_access(&self) -> bool
    {
        match self.state
        {
            RegionState::InUse =>
            {
                hvlog!("Granting {:?} access to 0x{:x} - 0x{:x}", AccessPermissions::ReadWriteExecute, self.base, self.end);
                platform::physmem::protect(self.base, self.end, AccessPermissions::ReadWriteExecute);
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

/* initialize the physical memory system by registering all available RAM as allocatable regions */
pub fn init() -> Result<(), Cause>
{
    match hardware::get_phys_ram_areas()
    {
        Some(ram_areas) => 
        {
            let mut regions = REGIONS.lock();
            for area in ram_areas
            {
                regions.push_front(Region::new(area.base, area.size, RegionState::Free));
            }
            Ok(())
        },
        None => Err(Cause::PhysNoRAMFound)
    }
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
