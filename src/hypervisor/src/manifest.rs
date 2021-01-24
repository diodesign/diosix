/* diosix hypervisor manifest file-system management
 *
 * (c) Chris Williams, 2020-2021.
 *
 * See LICENSE for usage and copying.
 */

use super::physmem;
use super::error::Cause;
use super::capsule;
use super::hardware;
use super::loader;
use super::virtmem::Mapping;
use super::vcore::Priority;
use dmfs::{ManifestImageIter, ManifestObject, ManifestObjectType, ManifestObjectData};
use alloc::string::String;
use alloc::vec::Vec;

/* bring in the built-in dmfs image */
use core::slice;
use core::intrinsics::transmute;
extern "C"
{
    static _binary_dmfs_img_start: u8;
    static _binary_dmfs_img_size: u8;
}

/* convert the included dmfs image into a byte slice */
macro_rules! get_dmfs_image
{
    () =>
    {
        unsafe
        {
            slice::from_raw_parts
            (
                transmute(&_binary_dmfs_img_start),
                transmute(&_binary_dmfs_img_size)
            )
        }
    }
}

/* return a list of a DMFS image's asset names and descriptions
   <= array of (names, descriptions) of image's assets */
pub fn list_assets() ->  Result<Vec<(String, String)>, Cause>
{
    let image = get_dmfs_image!();
    let manifest = match ManifestImageIter::from_slice(image)
    {
        Ok(m) => m,
        Err(_) => return Err(Cause::ManifestBadFS)
    };

    let mut list: Vec<(String, String)> = Vec::new();
    for asset in manifest
    {
        list.push((asset.get_name(), asset.get_description()));
    }

    Ok(list)
}

/* look up an asset from the given DMFS image by its name */
pub fn get_named_asset(name: &str) -> Result<ManifestObject, Cause>
{
    let image = get_dmfs_image!();
    let manifest = match ManifestImageIter::from_slice(image)
    {
        Ok(m) => m,
        Err(_) => return Err(Cause::ManifestBadFS)
    };

    for asset in manifest
    {
        /* sadly no simple strcmp() in rust? */
        if asset.get_name().as_str().starts_with(name) == true && asset.get_name().len() == name.len()
        {
            return Ok(asset);
        }
    }

    Err(Cause::ManifestNoSuchAsset)
}

/* parse the hypervisor's bundled manifest, creating services and capsules as required,
   and output any included boot banner messages, during system start up */
pub fn unpack_at_boot() -> Result<(), Cause>
{
    let image = get_dmfs_image!();
    let manifest = match ManifestImageIter::from_slice(image)
    {
        Ok(m) => m,
        Err(_) => return Err(Cause::ManifestBadFS)
    };

    for asset in manifest
    {
        match asset.get_type()
        {
            /* only unpack and process boot messages and system services at startup */
            ManifestObjectType::BootMsg => load_asset(asset)?,
            ManifestObjectType::SystemService => load_asset(asset)?,
            ManifestObjectType::GuestOS => load_asset(asset)?,
            _ => ()
        }
    }

    Ok(())
}

/* process the given asset, such as printing it to the debug output stream if it's a boot message
   or parsing it and running it if it's an executable, from the given DMFS image
   => asset = manifest asset to parse and process into memory
*/
pub fn load_asset(asset: ManifestObject) -> Result<(), Cause>
{
    let image = get_dmfs_image!();
    let content = match asset.get_contents()
    {
        ManifestObjectData::Bytes(b) => b.as_slice(),
        ManifestObjectData::Region(r) => &image[r.start..r.end]
    };

    match asset.get_type()
    {
        /* print the included boot message */
        ManifestObjectType::BootMsg =>
        {
            hvdebugraw!("\n{}\n\n", String::from_utf8_lossy(content));
            debughousekeeper!(); /* ensure the message is seen */
        },

        /* run a system service and ensure it auto-restarts if it crashes */
        ManifestObjectType::SystemService => match create_capsule_from_exec(true, content)
        {
            Ok(_) => hvdebug!("Created capsule for {}, {} bytes in manifest",
                        asset.get_description(), asset.get_contents_size()),
            Err(_e) => hvdebug!("Failed to create capsule for system service {}: {:?}", asset.get_name(), _e)
        },

        /* run an included guest OS */
        ManifestObjectType::GuestOS => match create_capsule_from_exec(false, content)
        {
            Ok(_) => hvdebug!("Created guest OS capsule for {}: {}, {} bytes in manifest",
                        asset.get_name(), asset.get_description(), asset.get_contents_size()),
            Err(_e) => hvdebug!("Failed to create capsule for system service {}: {:?}", asset.get_name(), _e)
        },

        t => hvdebug!("Found manifest object type {:?}", t)
    }

    Ok(())
}

/* create a capsule from an executable in a DMFS image
   => auto_crash_restart = true to restart this automatically in case of a crash
      binary = slice containing the executable to parse and load
   <= Ok, or an error code
*/
fn create_capsule_from_exec(auto_crash_restart: bool, binary: &[u8]) -> Result<(), Cause>
{
    /* create an auto-restarting capsule */
    let capid = capsule::create(auto_crash_restart)?;

    /* assign one virtual CPU core to the capsule */
    let cpus = 1;

    /* reserve 128MB of physical RAM for the capsule */
    let size = 128 * 1024 * 1024;
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
        capsule::add_vcore(capid, vcoreid, entry, guest_dtb_base, Priority::High)?;
    }

    Ok(())
}