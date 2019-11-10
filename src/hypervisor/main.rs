/* diosix hypervisor main entry code
 *
 * (c) Chris Williams, 2019.
 *
 * See LICENSE for usage and copying.
 */

/* let the compiler know we're on our own here in bare-metal world */
#![no_std]
#![no_main]
#![feature(asm)]

/* disable annoying warnings */
#![allow(dead_code)]
#![allow(unused_unsafe)]
#![allow(improper_ctypes)]

/* provide a framework for unit testing */
#![feature(custom_test_frameworks)]
#![test_runner(crate::run_tests)]
#![reexport_test_harness_main = "hvtests"] /* entry point for tests */

/* plug our custom heap allocator into the Rust language: Box, etc*/
#![feature(alloc_error_handler)]
#![feature(box_syntax)]
extern crate alloc;

/* needed for fast lookup tables of stuff */
extern crate hashbrown;

/* needed for elf parsing */
extern crate xmas_elf;

/* needed for lazyily-allocated static variables, and atomic ops */
#[macro_use]
extern crate lazy_static;
extern crate spin;
use spin::Mutex;

/* this will bring in all the hardware-specific code */
extern crate platform;

/* and now for all our non-hw specific code */
#[macro_use]
mod debug;      /* get us some kind of debug output, typically to a serial port */
mod hardware;   /* parse device trees into hardware objects */
mod heap;       /* per-CPU private heap management */
mod abort;      /* implement abort() and panic() handlers */
mod irq;        /* handle hw interrupts and sw exceptions, collectively known as IRQs */
mod physmem;    /* manage physical memory */
mod cpu;        /* manage CPU cores */
mod vcore;      /* virtual CPU core management... */
mod scheduler;  /* ...and scheduling */
mod capsule;    /* manage capsules */
mod loader;     /* parse and load supervisor binaries */

use cpu::{CPUId, BOOT_CPUID};

/* list of error codes */
mod error;
use error::Cause;

/* tell Rust to use our Kallocator to allocate and free heap memory.
while we'll keep track of physical memory, we'll let Rust perform essential
tasks, such as freeing memory when it's no longer needed, pointer checking, etc */
#[global_allocator]
static HV_HEAP: heap::HVallocator = heap::HVallocator;

/* set to true to allow physical CPU cores to start running supervisor code */
lazy_static!
{
    static ref INIT_DONE: Mutex<bool> = Mutex::new(false);
}

/* pointer sizes: do not assume this is a 32-bit or 64-bit system. it could be either.
in future, we may support 16- or 128-bit, too. stick to usize as much as possible */

/* NOTE: Do not call any hvlog/hvdebug macros until debug has been initialized */

/* hventry
   This is the official entry point of the Rust-level hypervisor.
   Call hvmain, which is where all the real work happens, and catch any errors.
   => cpu_nr = this boot-assigned CPU ID number
      device_tree_ptr = pointer to start of device tree structure
   <= return to infinite loop, awaiting interrupts */
#[no_mangle]
pub extern "C" fn hventry(cpu_nr: CPUId, device_tree_ptr: &u8)
{
    /* carry out tests if that's what we're here for */
    #[cfg(test)]
    hvtests();

    /* if not then start the system as normal */
    match hvmain(cpu_nr, device_tree_ptr)
    {
        Err(e) => hvalert!("hvmain bailed out with error: {:?}", e),
        _ => () /* continue waiting for an IRQ to come in */
    };
}

/* hvmain
   This code runs at the hypervisor level, with full physical memory access.
   Its job is to initialize physical CPU cores and other resources so that capsules can be
   created in which supervisors run that manage their own user space, in which
   applications run. The hypervisor ensures capsules are kept apart using
   hardware protections.

   Assumes all physical CPU cores enter this function during startup.
   The boot CPU is chosen to initialize the system in pre-SMP mode.
   If we're on a single CPU core then everything should still run OK.
   Assumes hardware and exception interrupts are enabled.

   => cpu_nr = arbitrary CPU core ID number assigned by boot code,
               separate from hardware ID number.
               BootCPUId = boot CPU core.
      device_tree = ptr to memory containing device tree describing the host hardware
   <= return to infinite loop, waiting for interrupts
*/
fn hvmain(cpu_nr: CPUId, device_tree: &u8) -> Result<(), Cause>
{
    /* set up each physical processor core with its own private heap pool and any other resources.
    each private pool uses physical memory assigned by the pre-hvmain boot code. init() should be called
    first thing to set up each processor core, including the boot CPU, which then sets up the global
    resources. all non-boot CPUs should wait until global resources are ready. */
    cpu::Core::init(cpu_nr);

    match cpu_nr
    {
        /* delegate to boot CPU the welcome banner and set up global resources */
        BOOT_CPUID => 
        {
            /* process device tree to create data structures representing system hardware,
            allowing these peripherals to be accessed by subsequent routines. this should
            also initialize any found hardware */
            hardware::parse_and_init(device_tree)?;
            hardware::debug_print();

            physmem::init()?; /* register all the available physical RAM */

            /* say hello via the debug port */
            hvlog!("Welcome to {} {}", env!("CARGO_PKG_NAME"), env!("CARGO_PKG_VERSION"));
            hvdebug!("Debugging enabled");

            /* initialize boot capsule */
            create_boot_capsule()?;

            /* allow other cores to continue */
            *(INIT_DONE.lock()) = true;
        },

        /* non-boot cores must wait here for early initialization to complete */
        _ => while *(INIT_DONE.lock()) != true {}
    }

    /* acknowledge we're alive and well, and report CPU core features */
    hvlog!("Physical CPU core {:?} ready to roll", cpu::Core::describe());

    /* enable timer on this physical CPU core to start scheduling and running virtual cores */
    scheduler::start()?;

    /* initialization complete. fall through to infinite loop waiting for a timer interrupt
    to come in. when it does fire, this stack will be flattened, a virtual CPU loaded up to run,
    and this boot thread will disappear like tears in the rain. */
    Ok(())
}

/* create the boot capsule, from which all other capsules spawn */
fn create_boot_capsule() -> Result<(), Cause>
{
    /* create a boot capsule with 128MB of RAM and one virtual core */
    let mem = 128 * 1024 * 1024;
    let cpus = 1;
    capsule::create_boot_capsule(mem, cpus)?;
    Ok(())
}

/* mandatory error handler for memory allocations */
#[alloc_error_handler]
fn kalloc_error(attempt: core::alloc::Layout) -> !
{
    hvalert!("alloc_error_handler: Failed to allocate/free {} bytes. Halting...", attempt.size());
    loop {} /* it would be nice to be able to not die here :( */
}

/* perform all unit tests required */
#[cfg(test)]
fn run_tests(unit_tests: &[&dyn Fn()])
{
    /* run each test one by one */
    for test in unit_tests
    {
        test();
    }

    /* exit cleanly once tests are complete */
    platform::test::end(Ok(0));
}

#[test_case]
fn test_assertion()
{
    assert_eq!(42, 42);
}