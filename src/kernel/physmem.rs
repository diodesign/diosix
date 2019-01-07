/* diosix machine kernel physical memory management
 *
 * Allocate/free memory for container supervisors
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
use platform::common::physmem;

lazy_static!
{
    /* acquire REGIONS lock before accessing any physical RAM regions */
    static ref REGIONS: Mutex<Box<LinkedList<Region>>> = Mutex::new(box LinkedList::new());
}

/* describe a region's use so the right access permissions can be assigned */
#[derive(Copy, Clone, Debug)]
pub enum RegionUse
{
    SupervisorCode = 0, /* read-execute-only area of the supervisor kernel */
    SupervisorData = 1, /* read-write data area of the supervisor kernel */
    ContainerRAM   = 2, /* read-write area for the container to use */
    Unused         = 4  /* unallocated */
}

/* describe a physical memory region */
#[derive(Copy, Clone)]
pub struct Region
{
    base: usize,
    end: usize,
    usage: RegionUse
}

impl Region
{
    /* enforce this region's access permissions, overwriting previous
    protections for the same usage type. this KISS approach should stop
    us losing track of regions and ensure scheduled containers always
    replace previous containers' access */
    pub fn protect(&self)
    {
        let perms = match self.usage
        {
            RegionUse::SupervisorCode => physmem::AccessPermissions::ReadExecute,
            RegionUse::SupervisorData => physmem::AccessPermissions::ReadWrite,
            RegionUse::ContainerRAM   => physmem::AccessPermissions::ReadWrite,
            RegionUse::Unused =>
            {
                kalert!("Enforcing access permissions on unused region?");
                physmem::AccessPermissions::NoAccess
            }
        };

        physmem::protect(self.usage as usize, self.base, self.end, perms);
    }

    /* return and change attributes */
    pub fn base(&self) -> usize { self.base }
    pub fn end(&self) -> usize { self.end }
    pub fn increase_base(&mut self, size: usize) { self.base = self.base + size; }
}

/* return the regions covering the builtin supervisor kernel's
executable code, and static data */
pub fn builtin_supervisor_code() -> Region
{
    let (base, end) = platform::common::physmem::builtin_supervisor_code();
    Region { base: base, end: end, usage: RegionUse::SupervisorCode }
}
pub fn builtin_supervisor_data() -> Region
{
    let (base, end) = platform::common::physmem::builtin_supervisor_data();
    Region { base: base, end: end, usage: RegionUse::SupervisorData }
}

/* intiialize the hypervisor's physical memory management.
   called once by the boot CPU core.
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
    from which future container physical RAM allocations will be drawn */
    let mut regions = REGIONS.lock();
    regions.push_front(Region
    {
        base: start,
        end: end,
        usage: RegionUse::Unused
    });

    return Some(available_bytes);
}

/* allocate a region of available physical memory for container use
   => size = number of bytes in region
      usage = what the region will be used for
   <= Region structure for the space, or an error code */
pub fn alloc_region(size: usize, usage: RegionUse) -> Result<Region, Cause>
{
    /* set to Some when we've found a suitable region */
    let mut area: Option<Region> = None;

    /* carve up the available ram for containers. this approach is a little crude
    but may do for now. it means containers can't grow */
    let mut regions = REGIONS.lock();
    for region in regions.iter_mut()
    {
        match region.usage
        {
            RegionUse::Unused =>
            {
                if (region.end() - region.base()) >= size
                {
                    /* free area is large enough for this requested region.
                    carve out an inuse region from start of free region,
                    and adjust free region's size. */
                    area = Some(Region
                    {
                        base: region.base(),
                        end: region.base() + size,
                        usage: usage
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
