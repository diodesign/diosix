/* diosix hypervisor physical memory management
 *
 * allocate/free contiguous regions of physical memory.
 * these regions are categorized into two groups,
 * depending on the region size.
 *
 * large: >= PHYS_RAM_LARGE_REGION_MIN_SIZE
 * large regions are sized in multiples of
 * PHYS_RAM_LARGE_REGION_MIN_SIZE and are allocated
 * from the top of free region blocks, descending.
 * these are aimed at large blocks of contiguous
 * memory for guest supervisor OSes.
 * 
 * small: < PHYS_RAM_LARGE_REGION_MIN_SIZE
 * small regions are sized in multiples of
 * PHYS_RAM_SMALL_REGION_MIN_SIZE and are allocated
 * from the bottom of free region blocks, ascending
 * these are aimed at small blocks of memory
 * for the hypervisor's private per-CPU heaps.
 * 
 * this arrangement is to avoid large and small
 * allocations fragmenting free region blocks
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

/* to avoid fragmentation, round up physical memory region allocations into multiples of these totals,
depending on the region type. this only applies when creating regions with alloc_region() */
const PHYS_RAM_LARGE_REGION_MIN_SIZE: PhysMemSize = 64 * 1024 * 1024; /* 64MB ought to be enough for anyone */
const PHYS_RAM_SMALL_REGION_MIN_SIZE: PhysMemSize =  1 * 1024 * 1024; /* smaller blocks are multiples of 1MB in size */

/* ensure large region bases are aligned down to multiples of this value
   note: region minimum size must be a non-zero multiple of region base alignment */
const PHYS_RAM_LARGE_REGION_ALIGNMENT: PhysMemSize = 4 * 1024 * 1024; /* 4MB alignment */

/* define whether to split a region N bytes from the top or from the bottom */
#[derive(Clone, Copy, Debug)]
pub enum RegionSplit
{
    FromBottom,
    FromTop
}

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

    /* split the region into two portions, lower and upper, and return the two portions
    => count = split the region this number of bytes into the block
       measure_from = FromBottom: count is number of bytes from bottom of the block, ascending
                      FromTop: count is number of bytes from the top of the block, descending
    <= return two portions as regions, lower and upper, or a failure code */
    pub fn split(&self, count: PhysMemSize, measure_from: RegionSplit) -> Result<(Region, Region), Cause>
    {
        /* check the split mark is within bounds */
        if count > self.size
        {
            return Err(Cause::PhysRegionSplitOutOfBounds);
        }

        /* return (lower, upper) */
        Ok(match measure_from
        {
            RegionSplit::FromBottom =>
            (
                Region::new(self.base, count),
                Region::new(self.base + count, self.size - count)
            ),
            
            RegionSplit::FromTop =>
            (
                Region::new(self.base, self.size - count),
                Region::new(self.base + self.size - count, count)
            ),
        })
    }
}

/* gather up all physical RAM areas from which future capsule and heap physical
RAM allocations will be drawn into the REGIONS list. this list is built from
available, free physical RAM: it must *not* include any RAM areas already in use by
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
       return an error code. */
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

/* allocate a region of available physical memory for guest capsule or hypervisor heap use.
   capsules should use large regions, and the heap should use small, ideally. 
   => size = number of bytes for the region, which will be rounded up to next multiple of:
     PHYS_RAM_LARGE_REGION_MIN_SIZE if the size >= PHYS_RAM_LARGE_REGION_MIN_SIZE (large type)
     PHYS_RAM_SMALL_REGION_MIN_SIZE if the size < PHYS_RAM_LARGE_REGION_MIN_SIZE (small type)

     note, large type regions will have a base address aligned down to PHYS_RAM_LARGE_REGION_ALIGNMENT
     this is so that guests that require 2MB or 4MB kernel alignment (eg RV64GC Linux) work as expected
     see: https://patchwork.kernel.org/patch/10868465/
     this code assumes the top of physically available RAM is aligned to PHYS_RAM_LARGE_REGION_ALIGNMENT

   <= Region structure for the space, or an error code */
pub fn alloc_region(size: PhysMemSize) -> Result<Region, Cause>
{
    /* determine where to split the free region block, and the region type */
    let (split_from, region_multiple) = if size >= PHYS_RAM_LARGE_REGION_MIN_SIZE
    {
        (RegionSplit::FromTop, PHYS_RAM_LARGE_REGION_MIN_SIZE)
    }
    else
    {
        (RegionSplit::FromBottom, PHYS_RAM_SMALL_REGION_MIN_SIZE)
    };

    /* round up to a multiple of the minimum size of a region type to avoid fragmentation */
    let adjusted_size = match size % region_multiple
    {
        0 => size,
        d => (size - d) + region_multiple
    };

    let mut regions = REGIONS.lock();
    match regions.find(adjusted_size) // find will remove found region from free list if successful 
    {
        Ok(found) => 
        {
            /* split the found region into two parts: one portion for the newly
            allocated region, and the remaining portion is returned to the free list.
            adjusted_size defines whwre in the region the split point occurs.
            split_from defines whether adjusted_size is measured from the top or
            bottom of the region block */
            match (found.split(adjusted_size, split_from), split_from)
            {
                /* split so that the lower portion is allocated, and the upper portion is returned to the free list */
                (Ok((lower, upper)), RegionSplit::FromBottom) =>
                {
                    regions.insert(upper)?;
                    Ok(lower)
                },

                /* split so that the upper portion is allocated, and the lower portion is returned to the free list */
                (Ok((lower, upper)), RegionSplit::FromTop) =>
                {
                    /* bring the base of the upper portion down to alignment mark */
                    let aligned_upper = match upper.base % PHYS_RAM_LARGE_REGION_ALIGNMENT
                    {
                        0 => Region::new(upper.base, upper.size),
                        d => Region::new(upper.base - d, upper.size + d)
                    };

                    /* fail out if upper portion crashes through the lower portion base after alignment */
                    if lower.size < aligned_upper.size - upper.size
                    {
                        return Err(Cause::PhysRegionRegionAlignmentFailure)
                    }

                    /* adjust the size of the lower portion if the upper portion was aligned down */
                    let adjusted_lower = match aligned_upper.size - upper.size
                    {
                        0 => lower,
                        d => Region::new(lower.base, lower.size - d)
                    };

                    regions.insert(adjusted_lower)?;
                    Ok(aligned_upper)
                },

                (Err(e), _) => Err(e)
            }
        },
        Err(_) => Err(Cause::PhysNotEnoughFreeRAM)
    }
}

/* deallocate a region so that its physical RAM can be reallocated.
   only accept samll regions that are multiples of PHYS_RAM_SMALL_REGION_MIN_SIZE
   and large regions that are multiples of PHYS_RAM_LARGE_REGION_MIN_SIZE
   => to_free = region to deallocate
   <= Ok for success, or an error code for failure */
pub fn dealloc_region(to_free: Region) -> Result<(), Cause>
{
    let size = to_free.size();

    /* police the size of the region */
    if size < PHYS_RAM_LARGE_REGION_MIN_SIZE
    {
        if size % PHYS_RAM_SMALL_REGION_MIN_SIZE != 0
        {
            return Err(Cause::PhysRegionSmallNotMultiple);
        }
    }
    else
    {
        if size % PHYS_RAM_LARGE_REGION_MIN_SIZE != 0
        {
            return Err(Cause::PhysRegionLargeNotMultiple);
        }
    }

    REGIONS.lock().insert(to_free)
}
