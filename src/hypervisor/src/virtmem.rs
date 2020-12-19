/* diosix capsule virtual memory management
 * 
 * (c) Chris Williams, 2019-2020.
 *
 * See LICENSE for usage and copying.
 */

use platform::physmem::PhysMemBase;
use platform::virtmem::VirtMemBase;
use super::physmem::Region;
use super::error::Cause;

/* map a capsule's virtual memory to a host physical memory region */
#[derive(Clone, Copy)]
pub struct Mapping
{
    virtual_base: Option<VirtMemBase>,
    physical_region: Option<Region>
}

impl Mapping
{
    /* create an empty mapping */
    pub fn new() -> Mapping
    {
        Mapping
        {
            virtual_base: None,
            physical_region: None
        }
    }

    /* define the virtual base address and corresponding physical RAM region */
    pub fn set_virtual(&mut self, vbase: VirtMemBase) { self.virtual_base = Some(vbase); }
    pub fn set_physical(&mut self, region: Region) { self.physical_region = Some(region); }
    pub fn get_physical(&self) -> Option<Region> { self.physical_region }

    /* set 1:1 mapping of virtual to physical addresses. requires physical region to be defined */
    pub fn identity_mapping(&mut self) -> Result<(), Cause>
    {
        match self.physical_region
        {
            Some(region) => self.virtual_base = Some(region.base()),
            None => return Err(Cause::VirtMemPhysNotSet)
        }
        Ok(())
    }

    /* translate host physical address to capsule virtual address using this mapping, or None for outside mapping
    or None if translation not possible as mapping is not configured */
    pub fn physical_to_virtual(&self, physaddr: PhysMemBase) -> Option<VirtMemBase>
    {
        match(self.virtual_base, self.physical_region)
        {
            (Some(virtbase), Some(region)) => if physaddr >= region.base() && physaddr < region.end()
            {
                Some((physaddr - region.base()) + virtbase)
            }
            else
            {
                None
            },
            (_, _ ) => None
        }
    }

    /* translate capsule virtual address to host physical address using this mapping, or None for outside mapping
    or None if translation not possible as mapping is not configured */
    pub fn virtual_to_physical(&self, virtaddr: VirtMemBase) -> Option<PhysMemBase>
    {
        match(self.virtual_base, self.physical_region)
        {
            (Some(virtbase), Some(region)) => if virtaddr >= virtbase && virtaddr < virtbase + region.size()
            {
                Some((virtaddr - virtbase) + region.base())
            }
            else
            {
                None
            },
            (_, _ ) => None
        }
    }
}
