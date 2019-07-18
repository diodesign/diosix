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
    /* debug */
    DebugFailure,

    /* heap */
    HeapNotInUse,
    HeapBadBlock,
    HeapNoFreeMem,
    HeapBadSize,

    /* physical memory */
    PhysMemBadConfig,
    PhysNotEnoughFreeRAM,

    /* CPU handling */
    CPUBadConfig,

    /* containers */
    CapsuleIDExhaustion,
    CapsuleBadID,

    /* scheduler and timer */
    SchedTimerBadConfig,
    
    /* supervisor binary loading */
    LoaderSupervisorTooLarge,
    LoaderUnrecognizedSupervisor,
    LoaderAccessFail
}
