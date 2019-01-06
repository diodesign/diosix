/* diosix hypervisor kernel main entry code
 *
 * (c) Chris Williams, 2018.
 *
 * See LICENSE for usage and copying.
 */

/* let the compiler know we're on our own here in bare-metal world */
#![no_std]
#![no_main]

#![feature(asm)]
#![allow(dead_code)]
#![allow(unused_unsafe)]
#![allow(improper_ctypes)]

/* we need this to plug our custom heap allocator into the Rust language */
#![feature(alloc_error_handler)]
#![feature(alloc)]
#![feature(box_syntax)]
extern crate alloc;

/* needed for lookup tables of stuff */
extern crate hashmap_core;

/* allow hypervisor and supervisor to use lazy statics and mutexes */
#[macro_use]
extern crate lazy_static;
extern crate spin;
use spin::Mutex;

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
mod scheduler;
use scheduler::Priority;
/* manage containers */
mod container;
/* list of kernel error codes */
mod error;
use error::Cause;

/* and our builtin supervisor kernel, which runs in its own container(s) */
mod supervisor;

/* tell Rust to use our kAllocator to allocate and free heap memory.
while we'll keep track of physical memory, we'll let Rust perform essential
tasks, such as freeing memory when it's no longer needed, pointer checking, etc */
#[global_allocator]
static KERNEL_HEAP: heap::Kallocator = heap::Kallocator;

/* set to true to allow physical CPU cores to start running supervisor code */
lazy_static!
{
    static ref INIT_DONE: Mutex<bool> = Mutex::new(false);
}

/* pointer sizes: do not assume this is a 32-bit or 64-bit system. it could be either.
stick to usize as much as possible */

/* kentry
   This is the official entry point of the Rust-level machine/hypervsor kernel.
   Call kmain, which is where all the real work happens, and catch any errors.
   => parameters described in kmain, passed directly from the bootloader...
   <= return to infinite loop, awaiting inerrupts */
#[no_mangle]
pub extern "C" fn kentry(cpu_nr: usize, device_tree_buf: &u8)
{
    match kmain(cpu_nr, device_tree_buf)
    {
        Err(e) => kalert!("kmain bailed out with error: {:?}", e),
        _ => () /* continue waiting for an IRQ to come in, otherwise */
    };
}

/* kmain
   This code runs at the machine/hypervisor level, with full physical memory access.
   Its job is to initialize CPU cores and other resources so that containers can be
   created that contain supervisor kernels that manage their own userspaces, in which
   applications run. The hypervisor ensures containers of apps are kept apart using
   hardware protections.

   Assumes all CPUs enter this function during startup.
   The boot CPU is chosen to initialize the system in pre-SMP mode.
   If we're on a single CPU core then everything should run OK.

   => cpu_nr = arbitrary ID number assigned by boot code, separate from hardware ID number.
               0 = boot CPU core.
      device_tree_buf = pointer to device tree describing the hardware
   <= return to infinite loop, waiting for interrupts
*/
fn kmain(cpu_nr: usize, device_tree_buf: &u8) -> Result<(), Cause>
{
    /* set up each processor core with its own private heap pool and any other resources.
    this uses physical memory assigned by the pre-kmain boot code. init() should be called
    first to set up every core, including the boot CPU, which then sets up the global
    resouces. all non-boot CPUs should wait until global resources are ready. */
    cpu::Core::init(cpu_nr);
    klog!("CPU core available and initialized");

    /* delegate to boot CPU the welcome banner and set up global resources */
    if cpu_nr == 0 /* boot CPU is zeroth core */
    {
        /* initialize global resources and root container */
        init_global(device_tree_buf)?;
        init_root_container()?;

        /* allow other cores to continue */
        *(INIT_DONE.lock()) = true;
    }

    /* non-boot cores must wait for early initialization to complete */
    while *(INIT_DONE.lock()) != true {}

    /* enable timer on this CPU core to sstart cheduling threads */
    scheduler::start();

    /* initialization complete. if we make it this far then fall through to infinite loop
    waiting for a timer interrupt to come in. when it does fire, this stack will be flattened,
    a virtual CPU loaded up to run, and this boot thread will disappear like tears in the rain. */
    Ok(())
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

    scheduler::init(device_tree)?;

    /* say hello */
    klog!("Welcome to diosix {} ... using device tree at {:p}", env!("CARGO_PKG_VERSION"), device_tree);
    klog!("Available RAM: {} MiB ({} bytes), CPU cores: {}", ram_size / 1024 / 1024, ram_size, cpus);
    kdebug!("... Debugging enabled");

    return Ok(());
}

/* create the root container */
fn init_root_container() -> Result<(), Cause>
{
    /* create root container with 4MB of RAM and max CPU cores */
    let root_mem = 4 * 1024 * 1024;
    let root_name = "root";
    let root_max_vcpu = 4;
    container::create_from_builtin(root_name, root_mem, root_max_vcpu)?;

    /* create a virtual CPU thread for the root container, starting it in sentry() with
    top of allocated memory as the stack pointer */
    scheduler::create_thread(root_name, supervisor::main::sentry, root_mem - 0x0000, Priority::High)?;
    scheduler::create_thread(root_name, supervisor::main::sentry, root_mem - 0x0000, Priority::High)?;
    scheduler::create_thread(root_name, supervisor::main::sentry, root_mem - 0x0000, Priority::High)?;
    scheduler::create_thread(root_name, supervisor::main::sentry, root_mem - 0x0000, Priority::High)?;
    Ok(())
}

/* mandatory error handler for memory allocations */
#[alloc_error_handler]
fn kalloc_error(attempt: core::alloc::Layout) -> !
{
    kalert!("alloc_error_handler: Failed to allocate/free {} bytes. Halting...", attempt.size());
    loop {} /* it would be nice to be able to not die here :( */
}
