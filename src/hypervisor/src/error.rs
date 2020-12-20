/* diosix error codes
 *
 * (c) Chris Williams, 2019-2020.
 *
 * See LICENSE for usage and copying.
 */

/* how things can go wrong */
#[derive(Debug)]
pub enum Cause
{
    /* misc */
    NotImplemented,

    /* debug */
    DebugInitFailed,

    /* devices */
    DeviceTreeBad,
    CantCloneDevices,
    BootDeviceTreeBad,

    /* physical CPU cores */
    PhysicalCoreBadID,
    PhysicalCoreCountUnknown,

    /* capsule services */
    ServiceAlreadyRegistered,
    ServiceNotAllowed,
    ServiceNotFound,

    /* messages */
    MessageBadType,

    /* heap */
    HeapNotInUse,
    HeapBadBlock,
    HeapNoFreeMem,
    HeapBadSize,

    /* host physical memory */
    PhysNoRAMFound,
    PhysNotEnoughFreeRAM,
    PhysRegionTooSmall,
    PhysRegionCollision,
    PhysRegionNoMatch,
    PhysRegionSplitOutOfBounds,
    PhysRegionRegionAlignmentFailure,
    PhysRegionSmallNotMultiple,
    PhysRegionLargeNotMultiple,

    /* capsule virtual memory */
    VirtMemPhysNotSet,

    /* containers */
    CapsuleIDExhaustion,
    CapsuleBadID,

    /* scheduler and timer */
    SchedNoTimer,
    
    /* supervisor binary loading */
    LoaderSupervisorTooLarge,
    LoaderUnrecognizedSupervisor,
    LoaderBadEntry,

    /* manifest errors */
    ManifestBadFS
}
