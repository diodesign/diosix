/* RISC-V CSR access
 *
 * (c) Chris Williams, 2019.
 *
 * See LICENSE for usage and copying.
 */

/* read_csr(csr name) returns contents of CSR */
macro_rules! read_csr
{
    ($csr:expr) =>
    {
        unsafe
        {
            let value: usize;
            asm!(concat!("csrrs $0, ", stringify!($csr), ", x0") : "=r"(value) ::: "volatile");
            value
        }
    };
}

/* write_csr(csr name, value to write) updates csr with value */
macro_rules! write_csr
{
    ($csr:expr, $value:expr) =>
    {
        unsafe
        {
            asm!(concat!("csrrw x0, ", stringify!($csr), ", $0") :: "r"($value) :: "volatile");
        }
    };
}
