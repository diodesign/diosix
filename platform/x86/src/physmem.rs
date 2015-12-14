/*
 * diosix microkernel 'menchi'
 *
 * Manage physical memory in x86 systems
 *
 * Maintainer: Chris Williams (diosix.org)
 *
 */

use errors::KernelInternalError;

use ::hardware::pgstack;
use ::hardware::paging;
use ::hardware::multiboot;

pub const SMALL_PAGE_SIZE: usize = 4 * 1024; /* size of a standard 4K physical page frame */
pub const LARGE_PAGE_SIZE: usize = 2 * 1024 * 1024; /* size of 2M phys page */

extern
{
    static kernel_start_addr: usize;
    static kernel_end_addr: usize;
    fn tidy_boot_pg_tables();
}

/* physical memory map
 *
 * System is booted using 2MB pages to identity map lowest 1GB of physical
 * memory into lowest 1GB of kernel virtual memory. This is what the
 * physical + virtual memory map will look for the kernel.
 *
 * --- zero ------------------------------------------------------------------
 *  Nasty low-level legacy x86 stuff.
 * --- 1MB -------------------------------------------------------------------
 *  Kernel loaded here with multiboot modules followed by free space to
 *  the 4MB mark (assumes kernel image will never take up more than 3MB).
 * --- 4MB -------------------------------------------------------------------
 *  Page stack starts here, growing up, followed by rest of physical
 *  memory and mapped-in IO devices.
 * --- end -------------------------------------------------------------------
 */

/* virtual memory map
 *
 * this is briefly detailed here because physical memory will be mapped into
 * the upper part of the kernel's virtual address space
 *
 * --- zero ------------------------------------------------------------------
 *  lower kernel space:
 *  booted with the lowest 1GB of physical memory mapped in here. init()
 *  below changes that so just the lowest 4MB is mapped in.
 * --- (0x0000000000400000) --------------------------------------------------
 *  userspace
 * --- (0x00007fffffffffff) --------------------------------------------------
 *  dead space - using it will trigger an exception
 * --- (0xffff800000000000) --------------------------------------------------
 *  upper kernel space:
 *  mirror all of physical memory, starting from zero from here.
 *  this gives the kernel 128TB of space to play with.
 * --- (0xffffffffffffffff) --------------------------------------------
 */

/* base of kernel's upper virtual address space area.
 * seems perverse defining this here. maybe move it later? */
const KERNEL_VIRTUAL_UPPER_BASE: usize = 0xffff800000000000;

/* init
 *
 * Initialize the physical memory management:
 * 1. find out how much physical RAM is available.
 * 2. build physical page frame stack, ensuring to protect kernel + page stack.
 * 3. map physical memory into kernel's upper virtual memory area using boot tables.
 * 4. load the new table structure into the CPU
 * 5. adjust physical page stack base address so we access it from the upper kernel space
 * 6. clear out the lower kernel space save for the first 4MB.
 *
 * <= returns error code on failure.
 */
pub fn init() -> Result<(), KernelInternalError>
{
    kprintln!("[x86] initializing physical memory");
    kprintln!("... kernel at {:x} to {:x} ({} KB)",
              kernel_start_addr, kernel_end_addr, (kernel_end_addr - kernel_start_addr) >> 10); 

    /* set up a page table structure using the boot page tables. the boot tables will serve as a
     * template for future page structures. */
    paging::BOOTPGTABL.lock().use_boot_pml4();
    
    let mut mem_total: usize = 0; /* total physical memory available */
    let mut mem_stacked: usize = 0; /* total we were able to stack - should be the same as mem_total */

    /* enumerate through the physical memory regions in two passes:
     *
     * first pass - total up the number of physical pages in the system so we can
     * calculate how large the page stacks will be.
     *
     * second pass - add physical pages to the stack frame and map into the kernel's
     * upper virtual memory. the first pass ensures we know how big the page stack will
     * be and avoid putting the page frames holding the stack onto the stack.
     */
    for pass in 1..3
    {
        try!(multiboot::MEMORYMAP.lock().init());
        let mut mem_map = multiboot::MEMORYMAP.lock();
        loop
        {
            match mem_map.enumerate()
            {
                Some(region) => match region.mem_type
                {
                    multiboot::MEM_REGION_USABLE =>
                    {
                        if pass == 1
                        {
                            /* first pass: just add up the available memory */
                            mem_total = mem_total + region.length as usize;
                        }
                        else
                        {
                            kprintln!("... ... RAM region found at 0x{:x}, size {} KB", region.base_addr, region.length >> 10);

                            /* second pass: add the pages to the stack and then map the pages into
                             * the kernel's upper virtual address space. map_phys_region() will try
                             * to obtain pages from the physical page stack, so use that after
                             * map_phys_region()
                             */
                            mem_stacked = mem_stacked + add_phys_region(region.base_addr as usize, region.length as usize).ok().unwrap_or(0);
                            try!(map_phys_region(region.base_addr as usize, region.length as usize));
                        }
                    },
                    _ => {}
                },
                None => break,
            }
        }

        /* set the limit of the page stack */
        if pass == 1
        {
            let pages: usize = mem_total / SMALL_PAGE_SIZE; /* convert bytes into 4k pages */
            kprintln!("... found {} physical pages", pages);
            try!(pgstack::SYSTEMSTACK.lock().set_limit(pages));
        }
    }
    kprintln!("... done, {} MB RAM available ({} bytes reserved for kernel use)", mem_total >> 20, mem_total - mem_stacked);
    
    /* get the physical page stack and paging code using the upper kernel area */
    pgstack::SYSTEMSTACK.lock().set_kernel_translation_offset(KERNEL_VIRTUAL_UPPER_BASE);
    paging::BOOTPGTABL.lock().set_kernel_translation_offset(KERNEL_VIRTUAL_UPPER_BASE);

    /* throw out all the redundant mappings, leaving just the kernel code, read-only data
     * and its bss scratch space mapped in the first 4MB of virtual memory. */
    unsafe{ tidy_boot_pg_tables(); }

    /* tell the CPU we're good to go with the new mappings */
    paging::BOOTPGTABL.lock().load();

    Ok(())
}

/* add_phys_region
 *
 * Break up a region of physical RAM into 4K pages and add each frame
 * to the physical page stack.
 * => base = lowest physical address of region
 *    size = number of bytes in the region
 * <= number of bytes stacked, or an error code on failure.
 */
fn add_phys_region(base: usize, size: usize) -> Result<usize, KernelInternalError>
{
    let total_pages = size / SMALL_PAGE_SIZE;
    let mut stacked = 0;

    for page_nr in 0..total_pages
    {
        let page_base = base + (page_nr * SMALL_PAGE_SIZE);

        /* check this physical page isn't already in use by
         * the physical memory holding the kernel text, rodata
         * and bss sections, and not the page stack.
         */
        if page_base >= kernel_start_addr && page_base < kernel_end_addr
        {
            continue;
        }

        let mut stack = pgstack::SYSTEMSTACK.lock();
        if stack.check_collision(page_base) == true
        {
            continue;
        }

        if stack.push(page_base).is_ok() == true
        {
            stacked = stacked + SMALL_PAGE_SIZE;
        }
    }

    Ok(stacked)
}

/* map_phys_region
 *
 * Map a region of physical memory into the kernel's upper virtual space
 * using the boot page tables and whole 2MB pages. the pages must be kernel only,
 * read/write and non executable. base will be aligned down to a 2M boundary
 * if it is not already aligned. the size will be rounded up to the next 2MB multiple.
 * => base = lowest physical address of region
 *    size = number of bytes in the region
 * <= returns error code on failure.
 */
fn map_phys_region(base: usize, size: usize) -> Result<(), KernelInternalError>
{
    let align_diff = base % LARGE_PAGE_SIZE;
    let base = base - align_diff; /* bring base down to a 2M page boundary */
    let size = size + align_diff; /* fix up size with extra bytes after alignment */

    /* fix up size so it rounds up to the next multiple of 2M */
    let size_diff = LARGE_PAGE_SIZE - (size % LARGE_PAGE_SIZE);
    let size = size + size_diff;

    let total_pages = size / LARGE_PAGE_SIZE;
    let flags = paging::PG_WRITEABLE | paging::PG_GLOBAL;

    for page_nr in 0..total_pages
    {
        let addr = base + (page_nr * LARGE_PAGE_SIZE);
        try!(paging::BOOTPGTABL.lock().map_2m_page(addr + KERNEL_VIRTUAL_UPPER_BASE,
                                                  addr, flags));
    }

    Ok(())
}

/* ---- easy access to pages of physical memory --------------------- */

/* get_page
 *
 * Grab a physical 4K page from the stack, translate its base address to
 * a kernel virtual address, and give it to the caller.
 * <= virtual address of page base, or an error code
 */
pub fn get_page() -> Result<usize, KernelInternalError>
{
    let page_base = try!(pgstack::SYSTEMSTACK.lock().pop());
    Ok(page_base + KERNEL_VIRTUAL_UPPER_BASE)
}

/* return_page
 *
 * Convert a kernel virtual address into a physical 4K page base address,
 * and return the page to the system for reuse.
 * => virtual address of page to return
 * <= error code on failure
 */
pub fn return_page(virt: usize) -> Result<(), KernelInternalError>
{
    /* sanity check */
    if virt < KERNEL_VIRTUAL_UPPER_BASE
    {
        return Err(KernelInternalError::BadVirtPgAddress);
    }

    let virt = virt - KERNEL_VIRTUAL_UPPER_BASE;
    try!(pgstack::SYSTEMSTACK.lock().push(virt));
    Ok(())
}

