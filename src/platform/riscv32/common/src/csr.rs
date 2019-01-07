/* RISC-V 32-bit CSR access
 *
 * (c) Chris Williams, 2019.
 *
 * See LICENSE for usage and copying.
 */

/* read_csr(csr number) returns contents of CSR */
macro_rules! read_csr
{
    ($csr:expr) =>
    {
        unsafe
        {
            let value: usize;
            asm!("csrrs $0, $1, x0" : "=r"(value) : "i"($csr) :: "volatile");
            value
        }
    };
}

/* write_csr(csr number, value to write) updates csr with value */
macro_rules! write_csr
{
    ($csr:expr, $value:ident) =>
    {
        unsafe
        {
            asm!("csrrw x0, $1, $0" :: "r"($value), "i"($csr) :: "volatile");
        }
    };
}

/* CSR numbers */
pub enum CSR
{
    Pmpcfg0 = 0x3a0,
    Pmpcfg1 = 0x3a1,
    Pmpcfg2 = 0x3a2,
    Pmpcfg3 = 0x3a3,

    Pmpaddr0 = 0x3b0,
    Pmpaddr1 = 0x3b1,
    Pmpaddr2 = 0x3b2,
    Pmpaddr3 = 0x3b3,
    Pmpaddr4 = 0x3b4,
    Pmpaddr5 = 0x3b5,
    Pmpaddr6 = 0x3b6,
    Pmpaddr7 = 0x3b7,
    Pmpaddr8 = 0x3b8,
    Pmpaddr9 = 0x3b9,
    Pmpaddr10 = 0x3ba,
    Pmpaddr11 = 0x3bb,
    Pmpaddr12 = 0x3bc,
    Pmpaddr13 = 0x3bd,
    Pmpaddr14 = 0x3be,
    Pmpaddr15 = 0x3bf
}
