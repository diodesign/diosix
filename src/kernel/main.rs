/* diosix machine/hypervisor kernel main entry code
 *
 * (c) Chris Williams, 2018.
 *
 * See LICENSE for usage and copying.
 */

/* let the compiler know we're on our own here in bare-metal world */
#![no_std]
#![no_main]

#![allow(dead_code)]
#![allow(unused_unsafe)]

/* we need this to plug our custom heap allocator into the Rust language */
#![feature(alloc_error_handler)]
#![feature(alloc)]
#![feature(box_syntax)]
extern crate alloc;

/* this will bring in all the hardware-specific code */
extern crate platform;

/* and now for all our non-hw specific code */
#[macro_use]
mod lock; /* multi-threading locking primitives */
#[macro_use]
mod debug; /* get us some kind of debug output, typically to a serial port */
mod heap; /* per-CPU private heap management */
mod abort; /* implement abort() and panic() handlers */
mod irq; /* handle hw interrupts and sw exceptions, collectively known as IRQs */
mod physmem; /* manage physical memory */
mod cpu; /* manage CPU cores */
/* manage supervisor environments */
mod environment;
/* list of kernel error codes */
mod error;
use error::Cause;

/* tell Rust to use ourr kAllocator to allocate and free heap memory.
while we'll keep track of physical memory, we'll let Rust perform essential
tasks, such as freeing memory when it's no longer needed, pointer checking, etc */
#[global_allocator]
static KERNEL_HEAP: heap::Kallocator = heap::Kallocator;

/* function naming note: hypervisor kernel entry points start with a k, such as kmain,
kirq_handler. supervisor entry points start with an s, such as smain.
generally, kernel = machine/hypervisor kernel, supervisor = supervisor kernel. */

/* pointer sizes: do not assume this is a 32-bit or 64-bit system. it could be either.
stick to usize as much as possible */

/* kentry
   This is the official entry point of the Rust-level machine/hypervsor kernel.
   Call kmain, which is where all the real work happens, and catch any errors.
   => parameters described in kmain, passed directly from the bootloader...
   <= return to infinite loop */
#[no_mangle]
pub extern "C" fn kentry(is_boot_cpu: bool, device_tree_buf: &u8)
{
    /* kentry is a safety net for kmain. if kmain returns then someting went
    wrong that we should recover from, or we note to the user that we hit 
    an unimplemented section of the kernel. */
    match kmain(is_boot_cpu, device_tree_buf)
    {
        Ok(()) => kdebug!("Exited kmain without error. That's all, folks."),
        Err(e) => kalert!("Exited kmain with error: {:?}", e)
    };
    /* for now, fall back to infinite loop. In future, try to recover */
}

/* kmain
   This code runs at the machine/hypervisor level, with full physical memory access.
   Its job is to create sandboxed environments in which supervisors run. There
   is a built-in supervisor in the supervisor directory. The hypervisor allocates regions of
   memory and CPU time to supervisors, which run applications in their own environments.

   Assumes all CPUs enter this function during startup.
   The boot CPU is chosen to initialize the system in pre-SMP mode.
   If we're on a single CPU core then everything should run OK.

   => is_boot_cpu = true if we're chosen to be the boot CPU, or false for every other CPU core
      device_tree_buf = pointer to device tree describing the hardware
   <= return to halt kernel on this core
*/
fn kmain(is_boot_cpu: bool, device_tree_buf: &u8) -> Result<(), Cause>
{
    /* set up each processor core with its own private heap pool and any other resources.
    this uses physical memory assigned by the pre-kmain boot code. this should be called
    first to set up every core, including the boot CPU, which then sets up the global
    resouces. all non-boot CPUs should wait until global resources are ready. */
    cpu::Core::init();

    /* delegate to boot CPU the welcome banner and set up global resources */
    if is_boot_cpu == true
    {
        /* initialize global resources */
        init_global(device_tree_buf)?;
        
        /* create root supervisor environment and linked list to store envs */
        environment::create(0)?;
    }

    Ok(()) /* return to infinite loop */
}

/* welcome the user and have the boot CPU initialize global structures and resources.
   <= return success, or failure code */
fn init_global(device_tree: &u8) -> Result<(), Cause>
{
    /* set up CPU management. discover how many CPUs we have */
    let cpus = match cpu::init(device_tree)
    {
        Some(c) => c,
        None =>
        {
            kalert!("CPU management failure: can't extract core count from config");
            return Err(Cause::CPUBadConfig);
        }
    };

    /* set up the physical memory management. find out available physical RAM */
    let ram_size = match physmem::init(device_tree)
    {
        Some(s) => s,
        None =>
        {
            kalert!("Physical memory failure: too little RAM, or config error");
            return Err(Cause::PhysMemBadConfig);
        }
    };

    /* say hello */
    klog!("Welcome to diosix {} ... using device tree at {:p}", env!("CARGO_PKG_VERSION"), device_tree);
    klog!("Available RAM: {} MiB ({} bytes), CPU cores: {}", ram_size / 1024 / 1024, ram_size, cpus);
    kdebug!("... Debugging enabled");

    return Ok(());
}

/* mandatory error handler for memory allocations */
#[alloc_error_handler]
fn kalloc_error(attempt: core::alloc::Layout) -> !
{
    kalert!("alloc_error_handler: Failed to allocate/free {} bytes. Halting...", attempt.size());
    loop {} /* it would be nice to be able to not die here :( */
}
