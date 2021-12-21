/* diosix high-level hypervisor's loader code for supervisor binaries
 *
 * Parses and loads supervisor-level binaries. It can perform basic
 * dynamic relocation, though not dynamic linking (yet). This
 * means guest kernels and system services 
 * It supports ELF and may support other formats in future.
 * 
 * (c) Chris Williams, 2019-2021.
 *
 * See LICENSE for usage and copying.
 */

#![allow(non_camel_case_types)]

use super::error::Cause;
use platform::cpu::Entry;
use super::physmem::Region;
use core::mem::size_of;
use xmas_elf;

/* supported CPU architectures */
#[derive(Debug)]
enum CPUArch
{
    /* see https://github.com/riscv/riscv-elf-psabi-doc/blob/master/riscv-elf.md#elf-object-file */
    RISC_V
}

/* supported ELF dynamic relocation types */
const R_RISCV_RELATIVE: u8 = 3;

/* xmas-elf is great but it doesn't help you out when you want to access Dynamic
   structs without duplicating a load of code for P32 and P64, hence this macro
   to wrap it up in one place */
macro_rules! get_abs_reloc_table
{
    ($dynstructs:ident) => {
    {
        let mut base = None;
        let mut size = None;
        let mut entry_size = None;

        for dynstruct in $dynstructs
        { 
            if let Ok(tag) = &dynstruct.get_tag()
            {
                match tag
                {
                    // defines the base offset of the absolute relocation table
                    xmas_elf::dynamic::Tag::Rela => if let Ok(ptr) = &dynstruct.get_ptr()
                    {
                        base = Some(*ptr as usize);
                    },
                    // defines the total size of the absolute relocation table 
                    xmas_elf::dynamic::Tag::RelaSize => if let Ok(val) = &dynstruct.get_val()
                    {
                        size = Some(*val as usize);
                    },
                    // defines the size of each absolute relocation table entry
                    xmas_elf::dynamic::Tag::RelaEnt => if let Ok(val) = &dynstruct.get_val()
                    {
                        entry_size = Some(*val as usize);
                    },
                    _ => ()    
                }
            }
        }

        (base, size, entry_size)
    }};
}

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

    /* get the processor target */
    let cpu = match elf.header.pt2.machine().as_machine()
    {
        xmas_elf::header::Machine::RISC_V => CPUArch::RISC_V,
        _ => return Err(Cause::LoaderUnrecognizedCPUArch)
    };
   
    /* the ELF binary defines the entry point as a virtual address. we'll be loading the ELF
       somewhere in physical RAM. we have to translate that address to a physical one */
    let mut entry_physical: Option<Entry> = None;
    let entry_virtual = elf.header.pt2.entry_point();

    /* we need to copy parts of the supervisor from the source to the target location in physical RAM.
    turn the region into a set of variables we can use */
    let target_base = target.base() as u64;
    let target_end = target.end() as u64;
    let target_size  = target.size() as u64;
    let target_as_bytes = target.as_u8_slice();
    let target_as_words = target.as_usize_slice();

    /* loop through program headers in the binary */
    for ph_index in 0..*(&elf.header.pt2.ph_count())
    {
        match &elf.program_header(ph_index)
        {
            Ok(ph) =>
            {
                match ph.get_type()
                {
                    /* copy an area in the binary from the source to the target RAM region */
                    Ok(xmas_elf::program::Type::Load) =>
                    {
                        /* reject binaries with load area file sizes greater than their mem sizes */
                        if ph.file_size() > ph.mem_size()
                        {
                            return Err(Cause::LoaderSupervisorFileSizeTooLarge);
                        }

                        /* we're loading the header into an arbitrary-located block of physical RAM.
                        we can't use the virtual address. we'll use the physical address as an offset
                        from target_base. FIXME: is this correct? what else can we use? */
                        let offset_into_image = ph.offset();
                        let offset_into_target = ph.physical_addr();
                        let copy_size = ph.file_size();

                        /* reject wild offsets and physical addresses */
                        if (offset_into_image + copy_size) > source.len() as u64
                        {
                            return Err(Cause::LoaderSupervisorBadImageOffset);
                        }
                        if (offset_into_target + copy_size) > target_size
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

                        /* do the copy */
                        target_as_bytes[offset_into_target as usize..(offset_into_target + copy_size) as usize].copy_from_slice
                        (
                            &source[(offset_into_image as usize)..(offset_into_image + copy_size) as usize]
                        );
                    },

                    /* support basic PIC ELFs by fixing up values in memory as instructed */
                    Ok(xmas_elf::program::Type::Dynamic) =>
                    {
                        /* support absolute relocation tables -- tables of memory locations to patch up based on where the ELF is loaded */
                        let (rela_tbl_base, rela_tbl_size, rela_tbl_entry_size) = match ph.get_data(&elf)
                        {
                            Ok(d) => match d
                            {
                                xmas_elf::program::SegmentData::Dynamic32(dynstructs) => get_abs_reloc_table!(dynstructs),
                                xmas_elf::program::SegmentData::Dynamic64(dynstructs) => get_abs_reloc_table!(dynstructs),
                                _ => (None, None, None)
                            },
                            /* fail binaries with bad metadata */
                            Err(_) => return Err(Cause::LoaderSupervisorBadDynamicArea)
                        };

                        /* if present, parse the absolute relocation table */
                        if rela_tbl_base.is_some() && rela_tbl_size.is_some() && rela_tbl_entry_size.is_some()
                        {
                            let rela_tbl_base = rela_tbl_base.unwrap();
                            let rela_tbl_size = rela_tbl_size.unwrap();
                            let rela_tbl_entry_size = rela_tbl_entry_size.unwrap();

                            /* fail binaries with bad metadata */
                            if (rela_tbl_base + rela_tbl_size) as u64 > target_size
                            {
                                return Err(Cause::LoaderSupervisorRelaTableTooBig);
                            }
                            if rela_tbl_entry_size == 0
                            {
                                return Err(Cause::LoaderSupervisorBadRelaEntrySize);
                            }

                            /* if these values are not word-aligned, loading will eventually gracefully fail */
                            let rela_tbl_nr_entries = rela_tbl_size / rela_tbl_entry_size;
                            let rela_tbl_words_per_entry = rela_tbl_entry_size / size_of::<usize>();
                            let rela_tbl_index_into_target = rela_tbl_base / size_of::<usize>();

                            /* read each absolute relocation table entry. layout is three machine words: 
                               [0] = offset into the target to alter
                               [1] = type of relocation to apply
                               [2] = value needed to compute the final relocation value */
                            for entry_nr in 0..rela_tbl_nr_entries
                            {
                                let index = rela_tbl_index_into_target + (entry_nr * rela_tbl_words_per_entry);
                                let offset = target_as_words.get(index + 0);
                                let info   = target_as_words.get(index + 1);
                                let addend = target_as_words.get(index + 2);

                                match (offset, info, addend)
                                {
                                    (Some(&o), Some(&i), Some(&a)) =>
                                    {   
                                        /* different CPU architectures have different relocation rules.
                                        relocation type is in the lower byte of the info word */
                                        match (&cpu, (i & 0xff) as u8)
                                        {
                                            /* absolute value relocation */
                                            (CPUArch::RISC_V, R_RISCV_RELATIVE) =>
                                            {
                                                let word_to_alter = o / size_of::<usize>();
                                                if let Some(word) = target_as_words.get_mut(word_to_alter)
                                                {
                                                    *word = a + target.base();
                                                }
                                                else
                                                {
                                                    /* give up on malformed binaries */
                                                    return Err(Cause::LoaderSupervisorBadRelaTblEntry);
                                                }
                                            },
                                            (_, _) =>
                                            {
                                                hvdebug!("Unknown {:?} ELF relocation type {:x}", &cpu, i);
                                                return Err(Cause::LoaderSupervisorUnknownRelaType);
                                            }
                                        }
                                    },
                                    (_, _, _) => return Err(Cause::LoaderSupervisorBadRelaTblEntry)
                                }
                            }
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
