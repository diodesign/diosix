/* diosix hypervisor main entry code
 *
 * (c) Chris Williams, 2019-2020.
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

/* plug our custom heap allocator into the Rust language: Box, etc */
#![feature(alloc_error_handler)]
#![feature(box_syntax)]
#[macro_use]
extern crate alloc;

/* needed to convert raw dtb pointer into a slice */
use core::slice;

/* needed for fast lookup tables of stuff */
extern crate hashbrown;

/* needed for elf parsing */
extern crate xmas_elf;

/* needed for device tree parsing and manipulation */
extern crate devicetree;

/* pass the feature qemudebug to be able to write direct to the emulator's stdout
via the macro qemuprint::println!() */
#[cfg(feature = "qemudebug")]
extern crate qemuprint;

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
#[macro_use]
mod heap;       /* per-CPU private heap management */
mod panic;      /* implement panic() handlers */
mod irq;        /* handle hw interrupts and sw exceptions, collectively known as IRQs */
#[macro_use]
mod physmem;    /* manage host physical memory */
mod virtmem;    /* manage capsule virtual memory */
mod pcore;      /* manage CPU cores */
mod vcore;      /* virtual CPU core management... */
mod scheduler;  /* ...and scheduling */
mod capsule;    /* manage capsules */
mod loader;     /* parse and load supervisor binaries */
mod message;    /* send messages between physical cores */
mod service;    /* allow capsules to register services */

use pcore::{PhysicalCoreID, BOOT_PCORE_ID};

/* list of error codes */
mod error;
use error::Cause;

/* tell Rust to use our HVallocator to allocate and free heap memory.
although we'll keep track of physical memory, we'll let Rust perform essential
tasks, such as dropping objects when it's no longer needed, borrow checking, etc */
#[global_allocator]
static HV_HEAP: heap::HVallocator = heap::HVallocator;

/* set to true to allow physical CPU cores to start running supervisor code */
lazy_static!
{
    static ref INIT_DONE: Mutex<bool> = Mutex::new(false);
}

/* a physical CPU core obtaining this lock when it is false must create the boot capsule
and set the flag to true. any other core obtaining it as true must release the lock */
lazy_static!
{
    static ref BOOT_CAPSULE_CREATED: Mutex<bool> = Mutex::new(false);
}

/* pointer sizes: do not assume this is a 32-bit or 64-bit system. it could be either.
in future, we may support 16- or 128-bit, too. stick to usize as much as possible */

/* hventry
   This is the official entry point of the Rust-level hypervisor.
   Call hvmain, which is where all the real work happens, and catch any errors.
   => cpu_nr = this boot-assigned CPU ID number
      dtb_ptr = pointer to start of device tree blob structure
      dtb_len = 32-bit big-endian length of the device tree blob
   <= return to infinite loop, awaiting interrupts */
#[no_mangle]
pub extern "C" fn hventry(cpu_nr: PhysicalCoreID, dtb_ptr: *const u8, dtb_len: u32)
{
    /* carry out tests if that's what we're here for */
    #[cfg(test)]
    hvtests();

    /* convert the dtb pointer into a slice: get this unsafe operation out of
    the way here so the rest of the hypervisor can parse the blob in
    a safe manner, assuming dtb_len is valid */
    let dtb = unsafe { slice::from_raw_parts(dtb_ptr, u32::from_be(dtb_len) as usize) };

    /* if not performing tests, start the system as normal */
    match hvmain(cpu_nr, dtb)
    {
        Err(e) =>
        {
            hvalert!("Hypervisor failed to start. Reason: {:?}", e);
            debughousekeeper!(); /* attempt to flush queued debug to output */
        },
        _ => () /* continue waiting for an IRQ to come in */
    };
}

/* hvmain
   This code runs at the hypervisor level, with full physical memory access.
   Its job is to initialize physical CPU cores and other resources so that capsules can be
   created in which supervisors run that manage their own user spaces, in which
   applications run. The hypervisor ensures capsules are kept apart using
   hardware protections.

   Assumes all physical CPU cores enter this function during startup.
   The boot CPU is chosen to initialize the system in pre-SMP mode.
   If we're on a single CPU core then everything should still run OK.
   Assumes hardware and exception interrupts are enabled and handlers
   installed.

   Also assumes all CPU cores are compatible ISA-wise. There is provision
   for marking some cores as more powerful than others for systems with
   a mix of performance and efficiency CPU cores.

   => cpu_nr = arbitrary CPU core ID number assigned by boot code,
               separate from hardware ID number.
               BOOT_PCORE_ID = boot CPU core.
      dtb = byte slice containing device tree blob describing the host hardware
   <= return to infinite loop, waiting for interrupts
*/
fn hvmain(cpu_nr: PhysicalCoreID, dtb: &[u8]) -> Result<(), Cause>
{
    /* set up each physical processor core with its own private heap pool and any other resources.
    each private pool uses physical memory assigned by the pre-hvmain boot code. init() should be called
    first thing to set up each processor core, including the boot CPU, which then sets up the global
    resources. all non-boot CPUs should wait until global resources are ready. */
    pcore::PhysicalCore::init(cpu_nr);

    /* note that pre-physmem::init(), CPU cores rely on their pre-hventry()-assigned
    heap space. after physmem::init(), CPU cores can extend their heaps using physical memory.
    the hypervisor will become stuck pre-physmem::init() if it goes beyond its assigned heap space. */

    match cpu_nr
    {
        /* delegate to boot CPU the welcome banner and set up global resources.
        note: the platform code should ensure whichever CPU core is assigned
        BOOT_PCORE_ID as its cpu_nr can initialize the hypervisor */
        BOOT_PCORE_ID => 
        {
            /* process device tree to create data structures representing system hardware,
            allowing these peripherals to be accessed by subsequent routines. this should
            also initialize any found hardware */
            hardware::parse_and_init(dtb)?;

            physmem::init()?; /* register all the available physical RAM */

            /* say hello via the debug port */
            hvlog!("Welcome to {} {}", env!("CARGO_PKG_NAME"), env!("CARGO_PKG_VERSION"));
            hvdebug!("Debugging enabled, {} CPU core(s) found", hardware::get_nr_cpu_cores().unwrap_or(0));

            /* allow other cores to continue */
            *(INIT_DONE.lock()) = true;
        },

        /* non-boot cores must wait here for early initialization to complete */
        _ => while *(INIT_DONE.lock()) != true {}
    }

    /* acknowledge we're alive and well, and report CPU core features */
    hvdebug!("Physical CPU core {:?} ready to roll", pcore::PhysicalCore::describe());

    /* the hypervisor can't make any assumptions about the underlying hardware.
    the boot capsule's device tree is derived from the host's device tree, modified
    to virtualize the peripherals. the virtual CPU cores that will run the capsule
    are based on the physical CPU core that creates it. ensure a suitable physical
    CPU core creates the boot capsule. this is more straightforward than the hypervisor
    getting stuck into trying to specify a hypothetical CPU core */
    if pcore::PhysicalCore::smode_supported() == true
    {
        match BOOT_CAPSULE_CREATED.try_lock()
        {
            Some(mut flag) => match *flag
            {
                false =>
                {
                    capsule::create_boot_capsule()?;
                    *flag = true;
                },
                true => ()
            },
            None => ()
        }
    }

    /* enable timer on this physical CPU core to start scheduling and running virtual cores */
    scheduler::start()?;

    /* initialization complete. fall through to infinite loop waiting for a timer interrupt
    to come in. when it does fire, this stack will be flattened, a virtual CPU loaded up to run,
    and this boot thread will disappear. thus, the call to start() should be the last thing
    this boot thread does */
    Ok(())
}

/* mandatory error handler for memory allocations */
#[alloc_error_handler]
fn hvalloc_error(attempt: core::alloc::Layout) -> !
{
    let heap = &(*<pcore::PhysicalCore>::this()).heap;
    hvalert!("hvalloc_error: Failed to allocate/free {} bytes. Heap: {:?}", attempt.size(), heap);
    debughousekeeper!();
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