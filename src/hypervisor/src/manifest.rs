/* diosix hypervisor manifest management
 *
 * (c) Chris Williams, 2020.
 *
 * See LICENSE for usage and copying.
 */

/* ignore String not being used outside of debug builds */
#![allow(unused_imports)]

use super::physmem;
use super::error::Cause;
use super::capsule;
use super::hardware;
use super::loader;
use super::virtmem::Mapping;
use super::vcore::Priority;
use dmfs::{ManifestImageIter, ManifestObjectType, ManifestObjectData};
use alloc::string::String;

/* parse the hypervisor's bundled manifest, creating services and capsules as required,
and output any included boot banner messages */
pub fn unpack(image: &[u8]) -> Result<(), Cause>
{
    let manifest = match ManifestImageIter::from_slice(image)
    {
        Ok(m) => m,
        Err(_) => return Err(Cause::ManifestBadFS)
    };

    for asset in manifest
    {
        /* represent the contents of the object as a byte slice */
        let content = match asset.get_contents()
        {
            ManifestObjectData::Bytes(b) => b.as_slice(),
            ManifestObjectData::Region(r) => &image[r.start..r.end]
        };

        match asset.get_type()
        {
            ManifestObjectType::BootMsg =>
            {
                hvdebugraw!("\n{}\n\n", String::from_utf8_lossy(content));
                debughousekeeper!(); /* ensure it's seen */
            },
            ManifestObjectType::SystemService => match create_service_capsule(content)
            {
                Ok(_) => hvdebug!("Created capsule for {}, {} bytes in manifest",
                            asset.get_description(), asset.get_contents_size()),
                Err(_e) => hvdebug!("Failed to create capsule for system service {}: {:?}", asset.get_name(), _e)
            },

            _t => hvdebug!("Found manifest object type {:?}", _t)
        }
    }

    Ok(())
}

/* create a capsule from an executable in memory
   => binary = slice containing the executable to parse and load
   <= Ok, or an error code
*/
fn create_service_capsule(binary: &[u8]) -> Result<(), Cause>
{
    /* create an auto-restarting capsule */
    let capid = capsule::create(true)?;

    /* assign one virtual CPU core to the capsule */
    let cpus = 1;

    /* reserve 64MB of physical RAM for the capsule */
    let size = 64 * 1024 * 1024;
    let ram = physmem::alloc_region(size)?;

    /* create device tree blob for the virtual hardware available to the guest
    capsule and copy into the end of the region's physical RAM.
    a zero-length DTB indicates something went wrong */
    let guest_dtb = hardware::clone_dtb_for_capsule(cpus, 0, ram.base(), ram.size())?;
    if guest_dtb.len() == 0
    {
        return Err(Cause::BootDeviceTreeBad);
    }

    let guest_dtb_base = ram.fill_end(guest_dtb)?;

    /* map that physical RAM into the capsule */
    let mut mapping = Mapping::new();
    mapping.set_physical(ram);
    mapping.identity_mapping()?;
    capsule::map_memory(capid, mapping)?;
    
    /* parse + copy the capsule's binary into its physical RAM */
    let entry = loader::load(ram, binary)?;

    /* create virtual CPU cores for the capsule as required */
    for vcoreid in 0..cpus
    {
        capsule::create_and_add_vcore(capid, vcoreid, entry, guest_dtb_base, Priority::High)?;
    }
    Ok(())
}