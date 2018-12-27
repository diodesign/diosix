/* diosix machine kernel physical memory management
 *
 * Allocate/free memory for supervisor environments
 * 
 * (c) Chris Williams, 2018.
 *
 * See LICENSE for usage and copying.
 */

use platform;
use spin::Mutex;
use error::Cause;
use alloc::boxed::Box;
use alloc::collections::linked_list::LinkedList;

lazy_static!
{
    /* acquire REGIONS lock before accessing any physical RAM regions */
    static ref REGIONS: Mutex<Box<LinkedList<RegionDesc>>> = Mutex::new(box LinkedList::new());
    static ref REGION_ID: Mutex<Box<RegionID>> = Mutex::new(box 1); /* ID zero reserved for free space */
}

pub type RegionID = usize;

/* describe a physical memory region */
#[derive(Copy, Clone)]
pub struct Region
{
    pub base: usize,
    pub end: usize
}

/* describe access permissions for a region */
pub enum Permissions
{
    ReadExecute,
    ReadOnly,
    ReadWrite,
    Unused
}

/* internal description of a physical memory region */
struct RegionDesc
{
    id: RegionID,
    region: Region,
    permissions: Permissions
}

/* return the regions covering the builtin supervisor kernel's
executable code, and static data */
pub fn builtin_supervisor_code() -> Region
{
    let (base, end) = platform::common::physmem::builtin_supervisor_code();
    Region { base: base, end: end }
}
pub fn builtin_supervisor_data() -> Region
{
    let (base, end) = platform::common::physmem::builtin_supervisor_data();
    Region { base: base, end: end }
}

/* intiialize the hypervisor's physical memory management.
   called once by the boot CPU core.
   Make no assumptions about the underlying hardware.
   the platform-specific code could set up per-CPU or
   per-NUMA domain page stacks, etc.
   we simply initialize the system, and then request
   and return physical pages as necessary.
   => device_tree_buf = pointer to device tree to parse
   <= number of bytes available, or None for failure
*/
pub fn init(device_tree_buf: &u8) -> Option<usize>
{
    /* let the underlying platform code work out how much RAM we have to play with */
    let available_bytes = match platform::common::physmem::init(device_tree_buf)
    {
        Some(s) => s,
        None => return None
    };
    let (start, end) = platform::common::physmem::allocatable_ram();

    /* create a free/unused region covering all of available phys RAM
    from which future allocations will be drawn */
    let mut regions = REGIONS.lock();
    regions.push_front(RegionDesc
    {
        id: 0,
        region: Region
        {
            base: start,
            end: end
        },
        permissions: Permissions::Unused
    });

    return Some(available_bytes);
}

/* allocate a region of available physical memory for supervisor environment use
   => size = number of bytes in region
   <= Region structure for the space, or an error code */
pub fn alloc_region(size: usize, access: Permissions) -> Result<Region, Cause>
{
    /* set to Some when we've found a suitable region */
    let mut area: Option<Region> = None;

    /* block until linked list is set up */
    loop { if REGIONS.lock().len() > 0 { break; } }

    /* carve up the available ram for environments. this approach is a little crude
    but may do for now. it means environments can't grow */
    let mut regions = REGIONS.lock();
    for region in regions.iter_mut()
    {
        match region.permissions
        {
            Permissions::Unused =>
            {
                if (region.region.end - region.region.base) >= size
                {
                    /* free area is large enough for this requested region.
                    carve out an inuse region from it and adjust size. */
                    area = Some(Region
                    {
                        base: region.region.base,
                        end: region.region. base + size
                    });
                    region.region.base = region.region.base + size;
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
            /* take current ID number and incrememnt ID for next region */
            let mut current_id = REGION_ID.lock();
            let id = **current_id;
            **current_id = **current_id + 1; /* TODO: deal with this potentially wrapping around */

            regions.push_front(RegionDesc
            {
                id: id,
                region: a,
                permissions: access
            });

            Ok(a) /* return bonds of new region */
        }
    }
}
