/* diosix machine/hypervisor kernel main entry code
 *
 * (c) Chris Williams, 2018.
 *
 * See LICENSE for usage and copying.
 */

/* let the compiler know we're on our own here in bare-metal world */
#![no_std]
#![no_main]

/* quieten complaints about unused code */
#![allow(dead_code)]

/* we need all this to plug our heap allocator into the Rust language */
#![feature(alloc_error_handler)]
#![feature(alloc)]
extern crate alloc;
/* this will bring in all the hardware-specific code */
extern crate platform;
/* use an external tree library */
extern crate ego_tree;
use ego_tree::Tree;

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

/* list of kernel error codes */
mod error;
use error::Cause;

/* tell Rust to use ourr kAllocator to allocate and free heap memory.
while we'll keep track of physical memory, we'll let Rust perform essential
tasks, such as freeing memory when it's no longer needed, pointer checking, etc */
#[global_allocator]
static KERNEL_HEAP: heap::kAllocator = heap::kAllocator;

/* function naming note: machine kernel entry points start with a k, such as kmain,
kirq_handler. supervisor kernel entry points start with an s, such as smain.
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
        Ok(()) => klog!("Exited kmain without error. That's all, folks."),
        Err(e) => kalert!("Exited kmain with error: {:?}", e)
    };
    /* for now, fall back to infinite loop. In future, try to recover */
}

/* kmain
   This code runs at the machine/hypervisor level, with full physical memory access.
   Its job is to create environments in which supervisor kernels run. Thus, the standard diosix
   kernel is split into two halves: a machine/hv lower half, and an upper half supervisor that
   manages user-mode code. This code here is starts that lower half.
   If we want to run a Linux or BSD-like environment, the upper half will be a Linux or BSD
   compatibility layer. The hypervisor allocates regions of memory and CPU time to supervisor
   kernels, which run applications in their own environments.

   Assumes all CPUs enter this function during startup.
   The boot CPU is chosen to initialize the system in pre-SMP mode.
   If we're on a single CPU core then everything should run OK.

   => is_boot_cpu = true if we're chosen to be the boot CPU, or false for every other CPU core
      device_tree_buf = pointer to device tree describing the hardware
   <= return to halt kernel on this core
*/
fn kmain(is_boot_cpu: bool, device_tree_buf: &u8) -> Result<(), Cause>
{
    /* make the boot CPU setup physical memory etc before other cores to come online */
    if is_boot_cpu == true
    {
        klog!("Welcome to diosix {} ... using device tree at {:p}", env!("CARGO_PKG_VERSION"), device_tree_buf);
        kdebug!("... Debugging enabled");

        pre_smp_init(device_tree_buf)?;
        klog!("Waking all CPUs");
    }

    /* set up all processor cores, including the boot CPU. all CPU cores will block in cpu::init()
    until released by the boot CPU in pre_smp_init(), allowing physical memory and other global
    resources to be prepared before being used */
    cpu::Core::init();


    
    Ok(()) /* return to infinite loop */
}

/* have the boot CPU perform any preflight checks and initialize the kernel prior to SMP.
   when the boot CPU is done, it should allow cores to exit cpu::int() by calling cpu::unblock_smp() 
   <= return success, or failure code */
fn pre_smp_init(device_tree: &u8) -> Result<(), Cause>
{
    /* set up the physical memory management */
    match physmem::init(device_tree)
    {
        Some(s) => klog!("Total physical memory available: {} MiB ({} bytes)", s / 1024 / 1024, s),
        None =>
        {
            kalert!("Physical memory failure: too little RAM, or config error");
            return Err(Cause::PhysMemBadConfig);
        }
    };

    /* everything's set up for all cores to run so unblock any waiting in cpu::init() */
    cpu::unblock_smp();
    return Ok(());
}

/* mandatory error handler for memory allocations */
#[alloc_error_handler]
fn kalloc_error(attempt: core::alloc::Layout) -> !
{
    kalert!("alloc_error_handler: Failed to allocate/free {} bytes. Halting...", attempt.size());
    loop {} /* it would be nice to be able to not die here :( */
}
