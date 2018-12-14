/* RISC-V 32-bit CPU management code
 *
 * (c) Chris Williams, 2018.
 *
 * See LICENSE for usage and copying.
 */

/* initialize this processor core. this is called by any core, boot CPU or not
=> cpu_nr = CPU ID number (0 = boot CPU)
<= return true for success, or false for failure */
pub fn init(cpu_nr: usize) -> bool
{
    return true;
}
