/* RISC-V 32-bit common exception/interrupt hardware-specific code
 *
 * (c) Chris Williams, 2018.
 *
 * See LICENSE for usage and copying.
 */

/* structure representing 30 registers stacked by low-level IRQ handler */
struct IRQRegisters
{
   ra: u32,  gp: u32, tp: u32, t0: u32, t1: u32, t2: u32, fp: u32, s1: u32,
   a0: u32,  a1: u32, a2: u32, a3: u32, a4: u32, a5: u32, a6: u32, a7: u32,
   s2: u32,  s3: u32, s4: u32, s5: u32, s6: u32, s7: u32, s8: u32, s9: u32,
  s10: u32, s11: u32, t3: u32, t4: u32, t5: u32, t6: u32
}

/* Handle synchronous exception triggered by programming error */
pub fn exception_handler()
{
}

/* Handle async or synchronous interrupt triggered during program execution */
pub fn interrupt_handler()
{
}
