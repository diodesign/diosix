/*
 * diosix microkernel 'menchi'
 *
 * Handle interrupts for x86 systems
 *
 * Maintainer: Chris Williams (diosix.org)
 *
 */

use ::hardware::pic;

/* init()
 *
 * Initialize the interrupt system with basic exception
 * and interrupt handling.
 *
 */
pub fn init()
{
    /* first things first, move the legacy PICs out of the way */
    pic::init();
}

