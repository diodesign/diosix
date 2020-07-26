/* diosix hypervisor physical memory management
 *
 * Allocate/free regions of memory for supervisors.
 * these regions can be used in 1:1 mappings or used
 * as RAM backing for virtual memory.
 * 
 * (c) Chris Williams, 2019-2020.
 *
 * See LICENSE for usage and copying.
 */

use platform;
use spin::Mutex;
use alloc::vec::Vec;
use platform::physmem::{PhysMemBase, PhysMemEnd, PhysMemSize, AccessPermissions, validate_ram};
use super::error::Cause;
use super::hardware;

/* return the physical RAM region covering the entirely of the boot capsule's supervisor */
pub fn boot_supervisor() -> Region
{
    let (base, end) = platform::physmem::boot_supervisor();
    Region { base: base, size: end - base }
}

/* to avoid fragmentation, round up physical memory region allocations into whole numbers of these bytes.
this only applies when creating regions with alloc_region() */
const PHYS_RAM_REGION_MIN_SIZE: PhysMemSize = 64 * 1024 * 1024; /* 64MB ought to be enough for anyone */

/* describe a physical memory region */
#[derive(Copy, Clone)]
pub struct Region
{
    base: PhysMemBase,
    size: PhysMemSize,
}

impl Region
{
    /* create a new region */
    pub fn new(base: PhysMemBase, size: PhysMemSize) -> Region
    {
        Region
        {
            base: base,
            size: size
        }
    }

    /* allow the currently running supervisor kernel to access this region of physical memory */
    pub fn grant_access(&self)
    {
        hvdebug!("Granting {:?} access to 0x{:x}, {} bytes", AccessPermissions::ReadWriteExecute, self.base, self.size);
        platform::physmem::protect(self.base, self.base + self.size, AccessPermissions::ReadWriteExecute);
    }

    /* return or change attributes */
    pub fn base(&self) -> PhysMemBase { self.base }
    pub fn end(&self) -> PhysMemEnd { self.base + self.size }
    pub fn size(&self) -> PhysMemSize { self.size }

    /* cut the region into two portions, at the 'count' byte mark. return two regions: the lower and upper
    portions of the split region, or a failure code */
    pub fn split(&self, count: PhysMemSize) -> Result<(Region, Region), Cause>
    {
        /* check the split mark is within bounds */
        if count > self.size
        {
            return Err(Cause::PhysRegionSplitOutOfBounds);
        }

        let lower = Region::new(self.base, count);
        let upper = Region::new(self.base + count, self.size - count);
        Ok((lower, upper))
    }
}

/* gather up all physical RAM areas from which future capsule physical
RAM allocations will be drawn into the REGIONS list. this list is built from
available physical RAM: it must *not* include any RAM areas already in use by
the hypervisor, boot supervisor image, peripherals, etc. the underlying
platform code needs to exclude those off-limits areas.

this list must also be sorted, by base address, lowest first. this is so that
adjoining regions can be merged into one. this list also contains only free
and available regions. if a region is in use, it must be removed from the list. */
lazy_static!
{
    /* acquire REGIONS lock before accessing any physical RAM regions */
    static ref REGIONS: Mutex<SortedRegions> = Mutex::new(SortedRegions::new());
}

/* implement a sorted list of regions */
struct SortedRegions
{
    regions: Vec<Region>
}

impl SortedRegions
{
    /* create an empty list */
    pub fn new() -> SortedRegions
    {
        SortedRegions
        {
            regions: Vec::new()
        }
    }

    /* find a region that has a size equal to or greater than the required size.
       if one is found, remove the region and return it. if one can't be found,
       return None. */
    pub fn find(&mut self, required_size: PhysMemSize) -> Result<Region, Cause>
    {
        for index in 0..self.regions.len()
        {
            if self.regions[index].size() >= required_size
            {
                /* remove from the list and return */
                return Ok(self.regions.remove(index));
            }
        }

        Err(Cause::PhysRegionNoMatch) /* can't find a region large enough */
    }

    /* insert a region into the list, sorted by base addresses, lowest first */
    pub fn insert(&mut self, to_insert: Region) -> Result<(), Cause>
    {
        /* ignore zero-size inserts */
        if to_insert.size() == 0
        {
            return Ok(())
        }

        for index in 0..self.regions.len()
        {
            if to_insert.end() <= self.regions[index].base()
            {
                self.regions.insert(index, to_insert);
                return Ok(())
            }

            /* check to make sure we're not adding a region that will collide with another */
            if to_insert.base() >= self.regions[index].base() && to_insert.base() < self.regions[index].end()
            {
                return Err(Cause::PhysRegionCollision);
            }
        }

        /* insert at the end: region greater than all others */
        self.regions.push(to_insert);
        Ok(())
    }

    /* merge all adjoining free regions. this requires the list to be sorted by base address ascending */
    pub fn merge(&mut self)
    {
        let mut cursor = 0;
        loop
        {
            /* prevent search from going out of bounds */
            if (cursor + 1) >= self.regions.len()
            {
                break;
            }

            if self.regions[cursor].end() == self.regions[cursor + 1].base()
            {
                /* absorb the next region's size into this region */
                self.regions[cursor].size = self.regions[cursor].size() + self.regions.remove(cursor + 1).size();
            }
            else
            {
                /* move onto next region */
                cursor = cursor + 1;
            }
        }
    }
}

/* initialize the physical memory system by registering all physical RAM available for use as allocatable regions */
pub fn init() -> Result<(), Cause>
{
    /* we need to know the CPU count so that any memory preallocated or reserved for the cores can be skipped */
    let nr_cpu_cores = match hardware::get_nr_cpu_cores()
    {
        Some(c) => c,
        None => return Err(Cause::PhysicalCoreCountUnknown)
    };

    /* the device tree defines chunks of memory that may or may not be entirely available for use */
    let chunks = match hardware::get_phys_ram_chunks()
    {
        Some(c) => c,
        None => return Err(Cause::PhysNoRAMFound)
    };

    /* iterate over the physical memory chunks... */
    let mut regions = REGIONS.lock();
    for chunk in chunks
    {
        /* ...and let validate_ram break each chunk in sections we can safely use */
        for section in validate_ram(nr_cpu_cores, chunk)
        {
            hvdebug!("Enabling RAM region 0x{:x}, size {} MB", section.base, section.size / 1024 / 1024);
            regions.insert(Region::new(section.base, section.size))?;
        }
    }

    Ok(())
}

/* perform housekeeping duties on idle physical CPU cores */
macro_rules! physmemhousekeeper
{
    () => ($crate::physmem::coalesce_regions());
}

pub fn coalesce_regions()
{
    REGIONS.lock().merge();
}

/* allocate a region of available physical memory for capsule use
   => size = number of bytes in region, rounded up to next multiple of PHYS_RAM_REGION_MIN_SIZE
   <= Region structure for the space, or an error code */
pub fn alloc_region(size: PhysMemSize) -> Result<Region, Cause>
{
    /* round up to a multiple of the minimum size of a region to avoid fragmentation */
    let adjusted_size = match size % PHYS_RAM_REGION_MIN_SIZE
    {
        0 => size,
        r => (size - r) + PHYS_RAM_REGION_MIN_SIZE
    };

    let mut regions = REGIONS.lock();
    match regions.find(adjusted_size) // find will remove found region if successful 
    {
        Ok(found) => 
        {
            /* split the found region into two parts: the lower portion for the newly
            allocated region, and the remaining upper portion which is returned to the free list */
            match found.split(adjusted_size)
            {
                Ok((lower, upper)) =>
                {
                    regions.insert(upper)?;
                    Ok(lower)
                },
                Err(e) => Err(e)
            }
        },
        Err(_) => Err(Cause::PhysNotEnoughFreeRAM)
    }
}

/* deallocate a region so that its physical RAM can be reallocated
   => to_free = region to deallocate
   <= Ok for success, or an error code for failure */
pub fn dealloc_region(to_free: Region) -> Result<(), Cause>
{
    REGIONS.lock().insert(to_free)
}
