/* diosix machine kernel code for handling hardware interrupts and software exceptions
 *
 * (c) Chris Williams, 2018.
 *
 * See LICENSE for usage and copying.
 */

/* platform-specific code must implement all this */
use platform;
use platform::common::irq::IRQContext;
use platform::common::irq::IRQType;
use platform::common::irq::IRQ;
use platform::common::cpu::PrivilegeMode;

/* kernel_irq_handler
   entry point for hardware interrupts and software exceptions, collectively known as IRQs.
   call down into platform-specific handlers
   => context = platform-specific context of the IRQ
   <= returns flag word describing IRQ
*/
#[no_mangle]
pub extern "C" fn kirq_handler(context: IRQContext)
{
    let irq = platform::common::irq::dispatch(context);

    match irq.irq_type
    {
        IRQType::Exception => exception(irq),
        IRQType::Interrupt => interrupt(irq),
    };
}

/* handle software exception */
fn exception(irq: IRQ)
{
    match (irq.fatal, irq.privilege_mode)
    {
        (true, PrivilegeMode::Kernel) =>
        {
            kalert!(
                "Fatal exception in kernel: {} at 0x{:x}, stack 0x{:x}",
                irq.debug_cause(),
                irq.pc,
                irq.sp
            );
            loop
            {}
        }
        (_, _) => (), /* ignore everything else */
    }
}

/* handle hardware interrupt */
fn interrupt(_irq: platform::common::irq::IRQ)
{
    kalert!("Hardware interrupt");
    loop
    {}
}
