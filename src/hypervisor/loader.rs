/* diosix high-level hypervisor loader code for supervisor
 *
 * (c) Chris Williams, 2019.
 *
 * See LICENSE for usage and copying.
 */

use error::Cause;
use platform::cpu::Entry;
use physmem::Region;
use goblin;

/* load a supervisor binary into memory as required
   => target = region of RAM to write into 
      source = region containing supervisor binary to parse
   <= ELF entry point if successful, or error code
*/
pub fn load(target: Region, source: Region) -> Result<Entry, Cause>
{
    let binary = source.base() as &[u8];

    match goblin::Object::parse(&binary)
    {
        Object::Elf(elf) =>
        {
            hvlog!("Loading ELF supervisor from 0x{:x} to 0x{:x}", source.base(), target.base());
            do_elf(target, source)
        },
        _ =>
        {
            hvalert!("Can't parse supervisor binary at 0x{:x}", source.base());
            Err(LoaderUnrecognizedSupervisor);
        }
    }
}

/* same arguments as load() except this time we know it's an ELF executable to parse:
   load the ELF at source into the physical RAM area target. don't use virtual addresses
   for placing program areas: calculate offsets into target RAM from file offsets */
fn do_elf(target: Region, source: Region) -> Result<Entry, Cause>
{
    let binary = source.base() as &[u8];

    match goblin::elf::Elf::parse(&binary)
    {
        Ok(elf) =>
        {
            let virt_entry = elf.entry;                 /* entry point in virtual address space */
            let mut real_entry: Option<usize> = None;   /* entry point where we're loading ELF in physical RAM */

            hvlog!("Supervisor ELF entry (virtual) address: 0x{:x}", entry);

            for header in elf.program_headers
            {
                if header.p_type == goblin::elf::program_header::PT_LOAD
                {
                    /* range of memory to copy from, starting from source */
                    let to_copy_from = header.file_range();
                    if to_copy_from.end > target.end()
                    {
                        /* not enough space in target area to hold this ELF executable */
                        return Err(LoaderSupervisorTooLarge);
                    }

                    /* copy program component into target memory area */
                    hvlog!("Copying {} bytes of ELF program from 0x{:x} (offset 0x{:x}) to 0x{}",
                            to_copy_from.end - to_copy_from.start, to_copy_from.start + source.base(),
                            to_copy_from.start, to_copy_from.start + target.base());
                    unsafe
                    {
                        /* definition is: copy_nonoverlapping<T>(src: *const T, dst: *mut T, count: usize) */
                        core::intrinsics::copy_nonoverlapping<u8>((to_copy_from.start + source.base()) *const u8,
                                                                  (to_copy_from.start + target.base()) as *const u8,
                                                                  to_copy_from.end - to_copy_from.start);
                    }

                    /* if entry point is in this program area's virtual space then convert it into a
                    physical RAM address in target */
                    if header.vm_range.contains(virt_entry) == true
                    {
                        let real_entry = Some((virt_entry - header.vm_range) + target.base());
                        hvlog!("Calculating entry point (0x:{:x}) physical RAM address: 0x{:x}",
                               virt_entry, (virt_entry - header.vm_range) + target.base());
                    }
                }
            }

            Ok(real_entry as Entry)
        },
        Err(e) =>
        {
            Malformed(s) =>
            {
                hvalert!("ELF malformed: {}", s);
                Err(LoaderUnrecognizedSupervisor)
            },
            BadMagic(m) =>
            {
                hvalert!("Bad magic found in ELF: 0x{:x}", m);
                Err(LoaderUnrecognizedSupervisor)
            }
            _ =>
            {
                hvalert!("Unable to access ELF executable");
                Err(LoaderAccessFail)
            }
        }
    }
}
