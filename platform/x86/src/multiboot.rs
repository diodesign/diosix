/*
 * diosix microkernel 'menchi'
 *
 * Parse Multiboot structures in x86 systems
 *
 * References: http://download-mirror.savannah.gnu.org/releases/grub/phcoder/multiboot.pdf
 * http://git.savannah.gnu.org/cgit/grub.git/tree/doc/multiboot2.h?h=multiboot2
 *
 * Maintainer: Chris Williams (diosix.org)
 *
 */

use errors::KernelInternalError;
use core::mem::size_of;
use spin::Mutex;

const MULTIBOOT_TAG_TYPE_MEM_MAP: u32 = 6;
pub const MEM_REGION_USABLE: u32 = 1; /* RAM region is available for use */

extern
{
    static multiboot_phys_addr: usize;
}

#[repr(C, packed)]
struct mb_header
{
    total_size: u32,    /* size of the multiboot data in bytes */
    reserved_zero: u32, /* must be zero */
    /* ... then an array of mb_tag_header structs, which vary in length */
}

#[repr(C, packed)]
struct mb_tag_header
{
    tag_type: u32,
    size: u32,          /* size of this tag not including padding */
    /* ... then the tag's data follows */
}

#[repr(C, packed)]
struct mem_map_tag
{
    /* tag type MULTIBOOT_TAG_TYPE_MEM_MAP:
     * describe a system's physical memory map */
    entry_size: u32,
    entry_version: u32,
    /* ... then an array of physical_mem_region structs */ 
}

#[repr(C, packed)]
pub struct physical_mem_region
{
    /* describe an individual region of physical memory */
    pub base_addr: u64,
    pub length: u64,
    pub mem_type: u32,
    reserved: u32,
}

/* return a pointer to the multiboot data's header */
fn get_mb_header() -> &'static mb_header
{
    unsafe{ &*(multiboot_phys_addr as *const mb_header) }
}

/* turn an offset from the start of the multiboot data into a pointer to a tag's header.
 * offset must be aligned to an 8-byte boundary because all tags start on an 8-byte boundary */ 
fn get_mb_tag_header(offset: usize) -> &'static mb_tag_header
{
    unsafe{ &*((multiboot_phys_addr + offset) as *const mb_tag_header) }
}

/* turn an offset from the start of the multiboot data into a pointer to a memory map tag header. */
fn get_mem_map_tag(offset: usize) -> &'static mem_map_tag
{
    unsafe{ &*((multiboot_phys_addr + offset) as *const mem_map_tag) }
}

/* turn an offset from the start of the multiboot data into a pointer to a memory map region
 * struct. */
fn get_physical_mem_region(offset: usize) -> &'static physical_mem_region
{
    unsafe{ &*((multiboot_phys_addr + offset) as *const physical_mem_region) }
}

/* align a multiboot data offset to the next 8-byte boundary, if not already aligned */
fn align_to_tag(mut offset: usize) -> usize
{
    if(offset & 0x07) != 0
    {
        offset = (offset & !0x07) + 0x08;
    }

    offset
}

/* find_tag
 *
 * Search for a tag by type and return the aligned offset from the start of the
 * multiboot data to the tag's start.
 * => tag_type = tag to search for
 * <= offset from multiboot data to tag, or a failure code
 */
fn find_tag(tag_type: u32) -> Result<usize, KernelInternalError>
{
    let mb = get_mb_header();
    let mut offset: usize = size_of::<mb_header>();

    loop
    {
        let tag = get_mb_tag_header(offset);
        if tag.tag_type == tag_type { return Ok(offset); }

        /* break if we hit a terminating tag (type = 0) */
        if tag.tag_type == 0 { break; }

        /* skip over this tag to the start of the next one */
        offset = offset + (tag.size as usize);

        /* make sure we're aligned to an 8-byte boundary - tags are padded
         * to these boundaries but their size fields do not include this
         * extra space. assumes the multiboot structure starts on an 8-byte boundary too. */
        offset = align_to_tag(offset);

        if offset >= (mb.total_size as usize) { break; } /* don't wander off the end of the mb struct */
    }

    Err(KernelInternalError::BadTag)
}

/* ---------- public routines to extract info from multiboot data --------- */

pub static MEMORYMAP: Mutex<PhysRAMRegions> = Mutex::new(PhysRAMRegions{offset_to_region: 0, base: 0});

pub struct PhysRAMRegions
{
    base: usize, /* offset from start of multiboot data to start of the memory map tag */
    offset_to_region: usize, /* offset from start of memory map tag to current region structure */
}

impl PhysRAMRegions
{
    /* call init() to start the process of searching for memory regions.
     * returns an error code on failure. */
    pub fn init(&mut self) -> Result<(), KernelInternalError>
    {
        /* set up offset so that it skips the headers and starts at the first memory region entry */
        self.offset_to_region = size_of::<mb_tag_header>() + size_of::<mem_map_tag>();
        self.base = try!(find_tag(MULTIBOOT_TAG_TYPE_MEM_MAP));
        Ok(())
    }

    /* call enumerate() to get a pointer to a region, or None for end of the list. */
    pub fn enumerate(&mut self) -> Option<&'static physical_mem_region>
    {
        /* check we haven't got to the end of the tag's data. If we have,
         * signal that there's nothing more to iterate. */
        let tag = get_mb_tag_header(self.base);
        if self.offset_to_region >= (tag.size as usize) { return None; }

        /* get the region from the current index */
        let region = get_physical_mem_region(self.base + self.offset_to_region);

        /* move onto next region and return the region we just found */
        let mem_map = get_mem_map_tag(self.base + size_of::<mb_tag_header>());
        self.offset_to_region = self.offset_to_region + (mem_map.entry_size as usize);
        Some(region)
    }
}


