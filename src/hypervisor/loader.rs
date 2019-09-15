/* diosix high-level hypervisor loader code for supervisor
 *
 * (c) Chris Williams, 2019.
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
      source = region containing supervisor binary to parse
   <= entry point in physical RAM if successful, or error code
*/
pub fn load(target: Region, source: Region) -> Result<Entry, Cause>
{
    let binary = unsafe { core::slice::from_raw_parts(source.base() as *const u8, source.size()) };
    let elf = match xmas_elf::ElfFile::new(binary)
    {
        Ok(elf) => elf,
        Err(s) =>
        {
            hvlog!("Failed to parse supervisor ELF (source physical RAM base 0x{:x}, size {} MiB): {}", source.base(), source.size() / 1024 / 1024, s);
            return Err(Cause::LoaderUnrecognizedSupervisor);
        }
    };

    /* the ELF binary defines the entry point as a virtual address. we'll be loading the ELF
       somewhere in physical RAM. we have to translate that address to a physical one */
    let mut entry_physical: Option<Entry> = None;
    let entry_virtual = elf.header.pt2.entry_point();

    /* we need to copy parts of the supervisor from the source to the target location in physical RAM */
    let (target_base, target_end)  = (target.base() as u64, target.end() as u64);
    let source_base = source.base() as u64;

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
                        /* sanity check: target must be able to hold supervisor */
                        if (target_base + ph.offset() + ph.mem_size()) > target_end
                        {
                            return Err(Cause::LoaderSupervisorTooLarge);
                        }

                        /* is this program header home to the entry point? if so, calculate the physical RAM address */
                        if entry_virtual >= ph.virtual_addr() && entry_virtual < ph.virtual_addr() + ph.mem_size()
                        {
                            entry_physical = Some((((entry_virtual as u64) - ph.virtual_addr()) + target_base) as usize);
                            hvlog!("Translated supervisor virtual entry point 0x{:x} to 0x{:x} in physical RAM",
                                entry_virtual, entry_physical.unwrap());
                        }

                        hvlog!("Loading supervisor ELF program area: 0x{:x} size 0x{:x} into 0x{:x}",
                               ph.offset() + source_base, ph.file_size(), ph.physical_addr() + target_base);
                        unsafe
                        {
                            /* definition is: copy_nonoverlapping<T>(src: *const T, dst: *mut T, count: usize) */
                            core::intrinsics::copy_nonoverlapping::<u8>((ph.offset() + source_base) as *const u8,
                                                                        (ph.physical_addr() + target_base) as *mut u8,
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