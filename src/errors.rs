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

    NoPhysPgAvailable, /* no physical page addresses available */

    PgStackFull, /* page stack is full */
}

