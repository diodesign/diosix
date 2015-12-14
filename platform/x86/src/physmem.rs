/*
 * diosix microkernel 'menchi'
 *
 * Manage physical memory in x86 systems
 *
 * Maintainer: Chris Williams (diosix.org)
 *
 */

use core::mem::size_of;
use core::ptr;
use spin::Mutex;
use errors::KernelInternalError;

use ::hardware::pages;
use ::hardware::multiboot;

extern
{
    static kernel_start_addr: usize;
    static kernel_end_addr: usize;
}

pub const PHYS_PAGE_SIZE: usize = 4096; /* size of a standard 4K physical page frame */
pub const PHYS_2M_PAGE_SIZE: usize = 2 * 1024 * 1024; /* size of 2M phys page */

const PAGE_STACK_PHYS_START: usize = 4 * 1024 * 1024; /* start page stack at 4MB mark in physical memory */

/* create a system-wide physical stack with a locking mechanism. */
pub static PAGESTACK: Mutex<PageStack> = Mutex::new(PageStack
                                                    {
                                                        base: PAGE_STACK_PHYS_START,
                                                        ptr: 0,
                                                        max_ptr: 0,
                                                        size: 0,
                                                    });

/* describe a physical page stack. we force Rust to give stack_base a
 * fixed kernel address, pointing to the base of the stack (natch).
 * we then manipulate the memory aboveit using .offset().
 * stack_ptr is the offset to the first empty slot, so 0 means an
 * empty stack and stack_max means a full stack. */

/* stack_base          stack_base + stack_ptr             stack_base + stack_max
 * |                   |                                  |
 * ++++++++++++++++++++...................................|
 *
 * Where + means a page is available and . means zero (no page)
 * stack_max is calculated from the total number of available physical pages.
 */

pub struct PageStack
{
    base: usize,     /* base address of this stack */
    max_ptr: usize,  /* ptr cannot be greater than stack_max */ 
    ptr: usize,      /* index into the stack, start form zero at the base */
    size: usize,     /* total size of the stack in memory in bytes */
}

impl PageStack
{
    /* set_limit
     *
     * Set the maximum number of entries allowed in the stack. You cannot
     * shrink the stack limit below the stack pointer. That would be unwise.
     * => limit = max number of pointer entries in the stack
     * <= returns error code on failure.
     */
    pub fn set_limit(&mut self, limit: usize) -> Result<(), KernelInternalError>
    {
        if limit < self.ptr
        {
            return Err(KernelInternalError::BadPgStackLimit);
        }

        self.max_ptr = limit;
        self.size = limit * size_of::<usize>();
        Ok(())
    }

    /* return true if addr falls within the physical address of the page stack,
     * or false if not. needed to ensure we don't reuse physical memory in use
     * by the page stack. */
    pub fn check_collision(&mut self, addr: usize) -> bool
    {
        if addr >= self.base && addr < (self.base + self.size) { return true; }

        false
    }

    /* push
     *
     * Stash a physical address on top of the stack and increment
     * the stack pointer. The address must be 4K aligned and the stack
     * must not be full.
     * => phys_addr = address to push onto the stack
     * <= returns error code on failure.
     */
    pub fn push(&mut self, phys_addr: usize) -> Result<(), KernelInternalError>
    {
        /* make sure we're not about to overflow the stack.
         * If ptr > max then something's gone really wrong.
         * move this into a sanity check elsewhere in the kernel? */
        if self.ptr >= self.max_ptr
        {
            return Err(KernelInternalError::PgStackFull);
        }

        /* make sure the physical address given is sane - it must
         * be aligned to the nearest 4K, thus the lowest 12 bits
         * must be clear. */
        if phys_addr & (PHYS_PAGE_SIZE - 1) != 0
        {
            return Err(KernelInternalError::BadPhysPgAddress);
        }
            
        /* calculate the address we need to write to in the stack,
         * write to it, and increment the stack pointer */
        unsafe
        {
            ptr::write(self.ptr_to_addr() as *mut _, phys_addr);
        }

        self.ptr = self.ptr + 1;
        Ok(())
    }

    /* pop
     *
     * Pop a physical page base address off the stack, if available.
     * <= returns address or error code on failure.
     */
    pub fn pop(&mut self) -> Result<usize, KernelInternalError>
    {
        /* bail out if there are no physical pages available (gulp) */
        if self.ptr == 0
        {
            return Err(KernelInternalError::NoPhysPgAvailable)
        }

        /* decrement the ptr, get the page address from the stack,
         * and then zero the stack entry */
        self.ptr = self.ptr - 1;
        let ptr_addr = self.ptr_to_addr();
        
        let pg_addr = unsafe
        {
            ptr::read(ptr_addr as *mut _)
        };

        unsafe
        {
            ptr::write(ptr_addr as *mut _, 0);
        }

        Ok(pg_addr)
    }

    /* calculate the full RAM address of the stack entry for the current ptr
     * so it can be used to access the entry. */
    fn ptr_to_addr(&mut self) -> usize
    {
        self.base + (self.ptr * size_of::<usize>())
    }
}

/* page stack design notes
 *
 * Each 1GB of physical RAM takes up 2MB of RAM: 262,144 x 8-byte pointers.
 * Each stacked pointer holds the base addresses of a physical page frame.
 * Pop the stack to obtain a pointer to an available page. Push the stack
 * to return a page for reuse.
 *
 * Start stack at first 4MB. Consider a sub-stack per CPU core?
 *
 */

/* physical memory map
 *
 * System is booted using 2MB pages to identity map lowest 1GB of physical
 * memory into lowest 1GB of kernel virtual memory. This is what the
 * physical + virtual memory map will look for the kernel.
 *
 * --- zero ------------------------------------------------------------------
 *  Nasty low-level legacy x86 stuff.
 * --- 1MB -------------------------------------------------------------------
 *  Kernel loaded here with multiboot modules.
 * --- ??? -------------------------------------------------------------------
 *  Free space to 4MB mark (assumes kernel will never take up more than 3MB).
 *  Convert this region into 4KB pages.
 * --- 4MB -------------------------------------------------------------------
 *  Page stack starts here, growing up
 * ---------------------------------------------------------------------------
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
    pages::BOOTPGTABL.lock().use_boot_pml4();
    
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
                            /* second pass: add the pages to the stack + map into the kernel */
                            kprintln!("... ... RAM region found at 0x{:x}, size {} KB", region.base_addr, region.length >> 10);
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
            let pages: usize = mem_total / PHYS_PAGE_SIZE; /* convert bytes into 4k pages */
            kprintln!("... found {} physical pages", pages);
            try!(PAGESTACK.lock().set_limit(pages));
        }
    }

    kprintln!("... done, {} MB RAM available ({} bytes reserved for kernel use)", mem_total >> 20, mem_total - mem_stacked);

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
    let total_pages = size / PHYS_PAGE_SIZE;
    let mut stacked = 0;

    for page_nr in 0..total_pages
    {
        let page_base = base + (page_nr * PHYS_PAGE_SIZE);

        /* check this physical page isn't already in use by
         * the physical memory holding the kernel text, rodata
         * and bss sections, and not the page stack.
         */
        if page_base >= kernel_start_addr && page_base < kernel_end_addr
        {
            continue;
        }

        let mut stack = PAGESTACK.lock();
        if stack.check_collision(page_base) == true
        {
            continue;
        }

        if stack.push(page_base).is_ok() == true
        {
            stacked = stacked + PHYS_PAGE_SIZE;
        }
    }

    Ok(stacked)
}

/* map_phys_region
 *
 * Map a region of physical memory into the kernel's upper virtual space
 * using the boot page tables and 2MB pages. the pages must be kernel only,
 * read/write and non executable. base will be aligned down to a 2M boundary
 * if it is not already aligned. this calls 
 * => base = lowest physical address of region
 *    size = number of bytes in the region
 * <= returns error code on failure.
 */
fn map_phys_region(base: usize, size: usize) -> Result<(), KernelInternalError>
{
    let align_diff = base % PHYS_2M_PAGE_SIZE;
    let base = base - align_diff; /* bring base down to a 2M page boundary */

    let total_pages = size / PHYS_2M_PAGE_SIZE;
    let flags = pages::PG_WRITEABLE;

    for page_nr in 0..total_pages
    {
        let addr = base + (page_nr * PHYS_2M_PAGE_SIZE);
        try!(pages::BOOTPGTABL.lock().map_2m_page(addr + KERNEL_VIRTUAL_UPPER_BASE,
                                                  addr, flags));
    }

    Ok(())
}

