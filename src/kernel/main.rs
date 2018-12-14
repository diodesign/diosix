/* diosix machine/hypervisor kernel main entry code
 *
 * (c) Chris Williams, 2018.
 *
 * See LICENSE for usage and copying.
 */

/* let the compiler know we're on our own here in bare-metal world */
#![no_std]
#![no_main]

/* this will bring in all the hardware-specific code */
extern crate platform;

#[macro_use]
mod debug; /* get us some kind of debug output, typically to a serial port */
mod abort; /* implement abort() and panic() handlers */
mod irq; /* handle hw interrupts and sw exceptions, collectively known as IRQs */
mod physmem; /* manage physical memory */
mod cpu; /* manage CPU cores */

/* function naming note: machine kernel entry points start with a k, such as kmain,
kirq_handler. supervisor kernel entry points start with an s, such as smain.
generally, kernel = machine/hypervisor kernel, supervisor = supervisor kernel. */

/* pointer sizes: do not assume this is a 32-bit or 64-bit system. it could be either.
stick to usize as much as possible */

/* kmain
   This code runs at the machine/hypervisor level, with physical memory access.
   Its job is to create environments in which supervisor kernels run. FWIW, the kernel is
   split into two halves: a machine/hv lower half, and an upper half supervisor that
   manages user-mode code. This code here is that lower half.

   Assumes all CPUs enter this function during startup.
   The boot CPU is chosen to initialize the system in pre-SMP mode.
   If we're on a single CPU core then everything should run OK.

   => cpu_nr  = CPU ID number. 0 = boot CPU
      device_tree_buf = phys RAM pointer to device tree describing the hardware
   <= return to halt kernel on this core
*/
#[no_mangle]
pub extern "C" fn kmain(cpu_nr: usize, device_tree_buf: &u8)
{
    /* make the boot CPU setup physical memory etc for other cores to come online */
    if cpu_nr == 0
    {
        pre_smp_init(device_tree_buf);
    }

    /* set up all processor cores, including the boot CPU */
    match cpu::init(cpu_nr)
    {
        true => klog!("CPU core initialized"),
        false =>
        {
            kalert!("Failed to initialize CPU core");
            return;
        }
    }
}

/* perform any preflight checks and initialize the kernel prior to SMP */
fn pre_smp_init(device_tree: &u8)
{
    klog!("Welcome to diosix {} ... using device tree at 0x{:x}", env!("CARGO_PKG_VERSION"), device_tree);

    /* set up the physical memory management */
    match physmem::init(device_tree)
    {
        Some(s) => klog!("Total physical memory available: {} MiB ({} bytes)", s / 1024 / 1024, s),
        None =>
        {
            kalert!("Physical memory failure: too little RAM, or config error");
            return;
        }
    };
}
