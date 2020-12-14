/* diosix hypervisor manifest management
 *
 * (c) Chris Williams, 2020.
 *
 * See LICENSE for usage and copying.
 */

use dmfs::{ManifestImageIter, ManifestObjectType};
use super::error::Cause;
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
        match asset.get_type()
        {
            ManifestObjectType::BootMsg =>
            {
                let _msg = String::from_utf8_lossy(asset.get_contents());
                hvdebug!("--- {} --- \n{}", asset.get_name(), _msg);
            },
            
            ManifestObjectType::SystemService => hvdebug!("Found service {} ({}), {} bytes in manifest",
                    asset.get_name(), asset.get_description(), asset.get_contents_size()),

            t => hvdebug!("Found object type {:?}", t)
        }
    }

    Ok(())
}
