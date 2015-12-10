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

use ::hardware::multiboot;

/* create a system-wide physical stack with a locking mechanism. */
pub static PAGESTACK: Mutex<PageStack> = Mutex::new(PageStack
                                                    {
                                                        base: PAGE_STACK_START,
                                                        ptr: 0,
                                                        max_ptr: 0
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
    base: usize, /* base address of this stack */
    max_ptr: usize,  /* ptr cannot be greater than stack_max */ 
    ptr: usize,  /* index into the stack, start form zero at the base */
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
        Ok(())
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
        if (phys_addr & 0xfff) != 0
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
const PAGE_STACK_START: usize = 4 * 1024 * 1024; /* start page stack at 4MB mark */

/* physical memory map
 *
 * System is booted using 2MB pages to identity map lowest 1GB of physical
 * memory into lowest 1GB of kernel virtual memory.
 *
 * --- 0MB -------------------------------------------------------------------
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

pub fn init() -> Result<(), KernelInternalError>
{
    kprintln!("[x86] initializing physical memory");

    multiboot::list_tags();

    kprintln!("... done");

    Ok(())
}

