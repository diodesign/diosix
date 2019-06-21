/* diosix machine kernel physical memory management
 *
 * Allocate/free memory for container supervisors
 * 
 * (c) Chris Williams, 2019.
 *
 * See LICENSE for usage and copying.
 */

use platform;
use spin::Mutex;
use error::Cause;
use alloc::boxed::Box;
use alloc::collections::linked_list::LinkedList;
use platform::physmem::{self, PhysMemBase, PhysMemEnd};

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
    base: PhysMemBase,
    end: PhysMemEnd,
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
    pub fn base(&self) -> PhysMemBase { self.base }
    pub fn end(&self) -> PhysMemEnd { self.end }
    pub fn increase_base(&mut self, size: PhysMemSize) { self.base = self.base + size; }
}

/* return the regions covering the builtin supervisor kernel's
executable code, and static data */
pub fn builtin_supervisor_code() -> Region
{
    let (base, end) = platform::physmem::builtin_supervisor_code();
    Region { base: base, end: end, usage: RegionUse::SupervisorCode }
}
pub fn builtin_supervisor_data() -> Region
{
    let (base, end) = platform::physmem::builtin_supervisor_data();
    Region { base: base, end: end, usage: RegionUse::SupervisorData }
}

/* intiialize the hypervisor's physical memory management.
   called once by the boot CPU core.
   => device_tree_buf = pointer to device tree to parse
   <= total number of bytes available, or 0 for failure
*/
pub fn init(device_tree_buf: &u8) -> PhysMemSize
{
    /* keep a running total of the number of bytes to play with */
    let mut available_bytes = 0;

    /* gather up all physical RaM areas from which future
    container physical RAM allocations will be drawn.
    this list is built from available physical RAM: it must not include
    any RAM areas already in use by the kernel, peripherals, etc.
    the undelying platform code needs to exclude those off-limits areas.
    in other words, available_ram() must only return fully usable RAM areas */
    let mut regions = REGIONS.lock();

    match physmem::available_ram(device_tree_buf)
    {
        Some(iter) => for area in iter
        {
            klog!("physical memory area found: {:x} {}", area.base, area.size);

            regions.push_front(Region
            {
                base: area.base,
                end: area.base + area.size,
                usage: RegionUse::Unused
            });

            available_bytes = available_bytes + area.size;
        },
        None => return None
    }

    return Some(available_bytes);
}

/* allocate a region of available physical memory for container use
   => size = number of bytes in region
      usage = what the region will be used for
   <= Region structure for the space, or an error code */
pub fn alloc_region(size: PhysMemSize, usage: RegionUse) -> Result<Region, Cause>
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
