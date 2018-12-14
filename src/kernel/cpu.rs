/* diosix machine kernel's CPU core management
 *
 * (c) Chris Williams, 2018.
 *
 * See LICENSE for usage and copying.
 */

/* platform-specific code must implement all this */
use platform;

/* intiialize CPU core. Prepare it for running supervisor code.
=> cpu_nr = CPU ID number (0 = boot CPU)
<= returns true if success, or false for failure */
pub fn init(cpu_nr: usize) -> bool
{
    return platform::common::cpu::init(cpu_nr);
}
