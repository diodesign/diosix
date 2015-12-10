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

use core::mem::size_of;

/* no locks involved because only the boot CPU should touch these functions.
 * and also: they're read only. */

extern
{
    static multiboot_phys_addr: usize;
}

#[repr(C, packed)]
struct mb_header
{
    total_size: u32,
    reserved_zero: u32,
    /* ... then an array of mb_tag_header structs, which vary in length */
}

#[repr(C, packed)]
struct mb_tag_header
{
    tag_type: u32,
    size: u32,
    /* ... then the tag's data follows */
}

#[repr(C, packed)]
struct mem_map_tag
{
    entry_size: u32,
    entry_version: u32,
    /* ... then an array of mem_map_entry structs */ 
}

#[repr(C, packed)]
struct mem_map_entry
{
    base_addr: u64,
    length: u64,
    mem_type: u32,
    reserved: u32,
}


fn get_mb_header() -> &'static mb_header
{
    unsafe{ &*(multiboot_phys_addr as *const mb_header) }
}

fn get_tag(offset: usize) -> &'static mb_tag_header
{
    unsafe{ &*((multiboot_phys_addr + offset) as *const mb_tag_header) }
}

fn align_to_tag(mut offset: usize) -> usize
{
    if(offset & 0x07) != 0
    {
        offset = (offset & !0x07) + 0x08;
    }

    offset
}

pub fn list_tags()
{
    let mb = get_mb_header();
    let mut offset: usize = size_of::<mb_header>();

    kprintln!("tags size: {}", mb.total_size);

    loop
    {
        let tag = get_tag(offset);
        kprintln!("tag: {} size {}", tag.tag_type, tag.size);

        /* break if we hit a terminating tag (type = 0) */
        if tag.tag_type == 0 { break; }

        /* skip over this tag to the start of the next one */
        offset = offset + (tag.size as usize);

        /* align to the next 8-byte boundary - tags are padded to these boundaries
         * but their size fields do not include this extra space. assumes 
         * the multiboot structure starts on an 8-byte boundary too. */
        offset = align_to_tag(offset);

        if offset >= (mb.total_size as usize) { break; } /* don't wander off the end of the mb struct */
    }
}

