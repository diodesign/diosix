/* diosix error codes
 *
 * (c) Chris Williams, 2019.
 *
 * See LICENSE for usage and copying.
 */

/* how things can go wrong */
#[derive(Debug)]
pub enum Cause
{
    /* Devices */
    BadDeviceTree,

    /* heap */
    HeapNotInUse,
    HeapBadBlock,
    HeapNoFreeMem,
    HeapBadSize,

    /* physical memory */
    PhysNoRAMFound,
    PhysNotEnoughFreeRAM,

    /* containers */
    CapsuleIDExhaustion,
    CapsuleBadID,

    /* scheduler and timer */
    SchedNoTimer,
    
    /* supervisor binary loading */
    LoaderSupervisorTooLarge,
    LoaderUnrecognizedSupervisor,
    LoaderBadEntry
}
