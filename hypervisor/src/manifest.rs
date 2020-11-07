/* diosix capsule manifest management
 *
 * (c) Chris Williams, 2020.
 *
 * See LICENSE for usage and copying.
 */

use dmfs;
use super::error::Cause;
use super::physmem::Region;
use super::capsule;

/* obtain the manifest of capsules included with the hypervisor and
create the boot-time capsules */
pub fn create_boot_capsules() -> Result<(), Cause>
{
    let manifest = match dmfs::parse_from_platform()
    {
        Some(m) => m,
        None => return Err(Cause::ManifestBadFS)
    };

    for asset in manifest
    {
        /* we're only interested in capsules cleared to run
        at boot time right now */
        let capsule = match asset
        {
            capsule::Kind::BootCapsule(c) => c,
            _ => continue
        };

        /* create a blank capsule and start prepping its configuration */
        let capid = capsule::create(capsule.autorestart)?;
        let cpus = capsule.cpus;
        let ram = physmem::alloc_region(capsule.ram_size)?;

        /* create device tree blob describing the virtual hardware available
        to the guest capsule and copy into the end of the region's physical RAM.
        a zero-length DTB indicates something went wrong */
        let guest_dtb = hardware::clone_dtb_for_capsule(cpus, 0, ram.base(), ram.size())?;
        if guest_dtb.len() == 0
        {
            return Err(Cause::BootDeviceTreeBad);
        }
        let guest_dtb_base = ram.fill_end(guest_dtb)?;

        /* map that physical memory into the capsule */
        let mut mapping = Mapping::new();
        mapping.set_physical(ram);
        mapping.identity_mapping()?;
        map_memory(capid, mapping)?;
        
        /* parse + copy the capsule's binary into its physical memory */
        let phys_ram_location = 
        let entry = loader::load(ram, capsule.phys_ram_location)?;

        /* create virtual CPU cores for the capsule as required */
        for vcoreid in 0..cpus
        {
            create_and_add_vcore(capid, vcoreid, entry, guest_dtb_base, Priority::High)?;
        }
    }

    Ok(())
}