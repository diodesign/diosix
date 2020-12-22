/* diosix high-level hypervisor loader code for supervisor
 *
 * (c) Chris Williams, 2019-2020.
 *
 * See LICENSE for usage and copying.
 */

use super::error::Cause;
use platform::cpu::Entry;
use super::physmem::Region;
use xmas_elf;

/* the long-term plan is to support multiple binary formats,
though initially we'll support ELF */

/* load a supervisor binary into memory as required
   => target = region of RAM to write into 
      source = slice containing supervisor binary image to parse
   <= entry point in physical RAM if successful, or error code
*/
pub fn load(target: Region, source: &[u8]) -> Result<Entry, Cause>
{
    let elf = match xmas_elf::ElfFile::new(source)
    {
        Ok(elf) => elf,
        Err(s) =>
        {
            hvalert!("Failed to parse supervisor ELF (source physical RAM base {:p}, size {} MiB): {}",
                     source, source.len() / 1024 / 1024, s);

            return Err(Cause::LoaderUnrecognizedSupervisor);
        }
    };

    /* the ELF binary defines the entry point as a virtual address. we'll be loading the ELF
       somewhere in physical RAM. we have to translate that address to a physical one */
    let mut entry_physical: Option<Entry> = None;
    let entry_virtual = elf.header.pt2.entry_point();

    /* we need to copy parts of the supervisor from the source to the target location in physical RAM */
    let (target_base, target_end, target_size)  = (target.base() as u64, target.end() as u64, target.size() as u64);

    /* loop through program headers in the binary */
    for ph_index in 0..elf.header.pt2.ph_count()
    {
        match elf.program_header(ph_index)
        {
            Ok(ph) =>
            {
                match ph.get_type()
                {
                    Ok(xmas_elf::program::Type::Load) =>
                    {
                        /* reject executables with load area file sizes greater than mem sizes */
                        if ph.file_size() > ph.mem_size()
                        {
                            return Err(Cause::LoaderSupervisorFileSizeTooLarge);
                        }

                        /* we're loading the header into an arbitrary-located block of physical RAM.
                        we can't use the virtual address. we'll use the physical address as an offset
                        from target_base. FIXME: is this correct? what else can we use? */
                        let offset_into_image = ph.offset();
                        let offset_into_target = ph.physical_addr();

                        /* reject wild offsets and physical addresses */
                        if (offset_into_image + ph.file_size()) > source.len() as u64
                        {
                            return Err(Cause::LoaderSupervisorBadImageOffset);
                        }
                        if (offset_into_target + ph.file_size()) > target_size
                        {
                            return Err(Cause::LoaderSupervisorBadPhysOffset);
                        }

                        /* is this program header home to the entry point? if so, calculate the physical RAM address.
                           assumes the entry point is a virtual address. FIXME: is there a better way of handling this? */
                        if entry_virtual >= ph.virtual_addr() && entry_virtual < ph.virtual_addr() + ph.mem_size()
                        {
                            let addr = (entry_virtual - ph.virtual_addr()) + target_base + offset_into_target;
                            if addr >= target_end
                            {
                                /* reject wild entry points */
                                return Err(Cause::LoaderSupervisorEntryOutOfRange);
                            }
                            entry_physical = Some(addr as usize);
                        }

                        unsafe
                        {
                            /* hvdebug!("ELF loader: offset into image {:x}, target {:x}; coping from src {:p} to dst {:p}, {} bytes",
                                offset_into_image, offset_into_target,
                                &source[ph.offset() as usize] as *const u8,
                                (target_base + offset_into_target) as *mut u8,
                                ph.file_size() as usize); */

                            /* definition is: copy_nonoverlapping<T>(src: *const T, dst: *mut T, count: usize) */
                            core::intrinsics::copy_nonoverlapping::<u8>(&source[offset_into_image as usize] as *const u8,
                                                                        (target_base + offset_into_target) as *mut u8,
                                                                        ph.file_size() as usize);
                        }
                    },
                    _ => ()
                }
            },
            _ => break
        };
    }

    match entry_physical
    {
        None => Err(Cause::LoaderBadEntry),
        Some(entry) => Ok(entry)
    }
}