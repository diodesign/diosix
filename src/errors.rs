/*
 * diosix microkernel 'menchi'
 *
 * Kernel error codes
 *
 * Maintainer: Chris Williams (diosix.org)
 *
 */

/* define error codes internal to the kernel */
pub enum KernelInternalError
{
    BadIndex, /* bad index to an array given as a parameter */
    BadPgStackLimit, /* bad page stack limit (less than current stack ptr) */
    BadPhysPgAddress, /* bad physical page addres (not aligned to page boundary) */
    BadTag, /* can't find tagged-data from bootloader */
    BadVirtPgAddress, /* bad virtual page addres (not aligned to page boundary) */

    HeapBadAllocReq, /* can't allocate requested block (probably too big) */
    HeapCorruption, /* heap is in an inconsistent state (fix it up?) */

    NoPhysPgAvailable, /* no physical page addresses available */

    Pg4KTablePresent, /* a 4KB page table is present (colliding with 2M page map request) */
    PgStackFull, /* page stack is full */
}

