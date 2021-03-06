/* diosix error codes
 *
 * (c) Chris Williams, 2019-2021.
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
    ServiceAlreadyOwner,
    ServiceNotAllowed,
    ServiceNotFound,

    /* messages */
    MessageBadType,

    /* heap */
    HeapNotInUse,
    HeapBadBlock,
    HeapNoFreeMem,
    HeapBadSize,
    HeapBadMagic,

    /* virtual core management */
    VirtualCoreBadID,
    VirtualCoreAWOL,

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

    /* capsules */
    CapsuleIDExhaustion,
    CapsuleBadID,
    CapsuleCannotRestart,
    CapsuleCantDie,
    CapsuleCantRestart,
    CapsuleBufferEmpty,
    CapsuleBufferWriteFailed,
    CapsuleMaxVCores,
    CapsuleBadPermissions,
    CapsulePropertyNotFound,

    /* scheduler and timer */
    SchedNoTimer,
    
    /* supervisor binary loading */
    LoaderUnrecognizedCPUArch,
    LoaderSupervisorTooLarge,
    LoaderSupervisorFileSizeTooLarge,
    LoaderSupervisorEntryOutOfRange,
    LoaderUnrecognizedSupervisor,
    LoaderSupervisorBadImageOffset,
    LoaderSupervisorBadPhysOffset,
    LoaderSupervisorBadDynamicArea,
    LoaderSupervisorBadRelaEntrySize,
    LoaderSupervisorRelaTableTooBig,
    LoaderSupervisorBadRelaTblEntry,
    LoaderSupervisorUnknownRelaType,
    LoaderBadEntry,

    /* manifest errors */
    ManifestBadFS,
    ManifestNoSuchAsset
}
