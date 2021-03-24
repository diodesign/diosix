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

/* drop in the dmfs image built by mkdmfs */
static DMFS_IMAGE: &[u8] = include_bytes!("../../mkdmfs/target/dmfs.img");

/* return a list of a DMFS image's asset names and descriptions
   <= array of (names, descriptions) of image's assets */
pub fn list_assets() ->  Result<Vec<(String, String)>, Cause>
{
    let manifest = match ManifestImageIter::from_slice(&DMFS_IMAGE)
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
    let manifest = match ManifestImageIter::from_slice(&DMFS_IMAGE)
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
    let manifest = match ManifestImageIter::from_slice(&DMFS_IMAGE)
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
    let properties = asset.get_properties();
    let content = match asset.get_contents()
    {
        ManifestObjectData::Bytes(b) => b.as_slice(),
        ManifestObjectData::Region(r) => &DMFS_IMAGE[r.start..r.end]
    };
    
    match asset.get_type()
    {
        /* print the included boot message */
        ManifestObjectType::BootMsg =>
        {
            hvdebugraw!("\r\n{}\r\n\r\n", String::from_utf8_lossy(content));
            debughousekeeper!(); /* ensure the message is seen */
        },

        /* create and run a system service */
        ManifestObjectType::SystemService => match create_capsule_from_exec(content, Some(properties))
        {
            Ok(cid) => hvdebug!("Created system service {} ({}) {} bytes (capsule {})",
                        asset.get_name(), asset.get_description(), asset.get_contents_size(), cid),
            Err(_e) => hvdebug!("Failed to create capsule for system service {}: {:?}", asset.get_name(), _e)
        },

        /* create an included guest OS (which does not have any special permissions) */
        ManifestObjectType::GuestOS => match create_capsule_from_exec(content, None)
        {
            Ok(cid) => hvdebug!("Created guest OS {} ({}) {} bytes (capsule {})",
                        asset.get_name(), asset.get_description(), asset.get_contents_size(), cid),
            Err(_e) => hvdebug!("Failed to create capsule for system service {}: {:?}", asset.get_name(), _e)
        },

        t => hvdebug!("Found manifest object type {:?}", t)
    }

    Ok(())
}

/* create a capsule from an executable in a DMFS image
   => binary = slice containing the executable to parse and load
      properties = permissions and other properties to grant the capsule, or None
   <= Ok with capusle ID, or an error code
*/
fn create_capsule_from_exec(binary: &[u8], properties: Option<Vec<String>>) -> Result<capsule::CapsuleID, Cause>
{
    /* assign one virtual CPU core to the capsule */
    let cpus = 1;

    /* create capsule with the given properties */
    let capid = capsule::create(properties, cpus)?;

    /* reserve 256MB of physical RAM for the capsule */
    let size = 256 * 1024 * 1024;
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

    Ok(capid)
}