/* diosix high-level hypervisor loader code for supervisor
 *
 * (c) Chris Williams, 2019.
 *
 * See LICENSE for usage and copying.
 */

use error::Cause;
use platform::cpu::Entry;
use physmem::Region;
use xmas_elf;

/* the long-term plan is to support multiple binary formats,
though initially we'll support ELF */

/* load a supervisor binary into memory as required
   => target = region of RAM to write into 
      source = region containing supervisor binary to parse
   <= entry point if successful, or error code
*/
pub fn load(target: Region, source: Region) -> Result<Entry, Cause>
{
    let binary = unsafe { core::slice::from_raw_parts(source.base() as *const u8, source.size()) };
    let elf = match xmas_elf::ElfFile::new(binary)
    {
        Ok(elf) => elf,
        Err(s) =>
        {
            hvlog!("Failed to parse supervisor ELF: {}", s);
            return Err(Cause::LoaderUnrecognizedSupervisor);
        }
    };

    let mut entry = None;
    let mut ph_index = 0;
    loop
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
                        if (target.base() as u64 + ph.offset() + ph.file_size()) > target.end() as u64
                        {
                            return Err(Cause::LoaderSupervisorTooLarge);
                        } 

                        hvlog!("loading ELF program area: 0x{:x} size 0x{:x} into 0x{:x}",
                               ph.offset() + source.base() as u64, ph.file_size(), ph.physical_addr() + target.base() as u64);
                        unsafe
                        {
                            /* definition is: copy_nonoverlapping<T>(src: *const T, dst: *mut T, count: usize) */
                            core::intrinsics::copy_nonoverlapping::<u8>((ph.offset() + source.base() as u64) as *const u8,
                                                                        (ph.physical_addr() + target.base() as u64) as *mut u8,
                                                                        ph.file_size() as usize);
                        }

                        /* assume entry point is the first address loaded: can't query xmas-elf for it :-( */
                        if ph_index == 0
                        {
                            entry = Some(ph.offset() + target.base() as u64);
                        }
                    },
                    _ => ()
                }
            },
            _ => break
        };

        ph_index = ph_index + 1;
    }

    /* if we've not defined an entry point by now then bail out */
    match entry
    {
        None => return Err(Cause::LoaderBadEntry),
        Some(e) => 
        {
            hvlog!("Supervior kernel entry = 0x{:x}", e);
            return Ok(unsafe { core::intrinsics::transmute(e) });
        }
    }
}
