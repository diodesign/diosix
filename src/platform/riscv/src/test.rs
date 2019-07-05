/* diosix RV32/RV64 test harness support
 *
 * (c) Chris Williams, 2019.
 *
 * See LICENSE for usage and copying.
 */

/* SiFive / Qemu defined a simple API for returning from tests with the all OK
or an error code. See: https://github.com/qemu/qemu/blob/master/hw/riscv/sifive_test.c
and https://github.com/qemu/qemu/blob/master/include/hw/riscv/sifive_test.h for magic numbers

Essentially, call end() with either Ok() to end the emulation as a success (all tests passed)
or with Err(n) where n is the code for the first test to fail */

/* end the test run by killing the underlying SiFive/Qemu-compatible emulator
   => result = OK to end successfully, passing 0 to host environment, or...
               Err(x) to return error code x to host environment
   <= never returns
*/
pub fn end(result: Result<u32, u32>)
{
    match result 
    {
        Ok(_) => write_word(0x5555), /* magic word to end with success, all tests passed */
        Err(e) => write_word(0x3333 | (e << 16)) /* magic word to end with fail, code in upper 16-bits of 32-bit word */
    }
}

/* write word to the SiFive / Qemu test interface fixed at 0x100000 on Virt environments */
fn write_word(word: u32)
{
    unsafe
    {
        asm!("sw $0, 0($1)" :: "r"(word), "r"(0x100000) ::);
    }
}