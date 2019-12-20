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
    /* misc */
    NotImplemented,

    /* devices */
    DeviceTreeBad,

    /* physical CPU cores */
    PhysicalCoreBadID,

    /* capsule services */
    ServiceAlreadyRegistered,
    ServiceNotAllowed,

    /* messages */
    MessageBadType,

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
