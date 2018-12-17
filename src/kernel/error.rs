/* diosix error codes
 *
 * (c) Chris Williams, 2018.
 *
 * See LICENSE for usage and copying.
 */

/* how things can go wrong */
#[derive(Debug)]
pub enum Cause
{
    /* heap */
    HeapNotInUse,
    HeapBadBlock,
    HeapNoFreeMem,

    /* physical memory */
    BadPhysMemConfig,
}
