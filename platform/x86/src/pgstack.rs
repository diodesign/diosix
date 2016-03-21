/*
 * diosix microkernel 'menchi'
 *
 * Allocate and deallocate physical memory in x86 systems
 *
 * Maintainer: Chris Williams (diosix.org)
 *
 */

use core::mem::size_of;
use core::ptr;
use spin::Mutex;
use errors::KernelInternalError;

use ::hardware::physmem;

/* two stacks are used to manage physical page allocations.
 * the low stack is 0-1GB and the high stack is 1GB+.
 * there are two stacks because during early kernel init, just the first 1GB of phys mem is mapped
 * in. this memory is needed to initialize the rest of the system. any allocations must therefore
 * come off the low stack - the pages referenced by the high stack are not available.
 * STACK_SPLIT_PHYS_ADDR  defines that split. in future, page stacks could be split by NUMA regions */
const STACK_SPLIT_PHYS_ADDR: usize = 1 * 1024 * 1024 * 1024;

/* start page stack at 4MB mark in physical memory. the high stack follows immediately after the
 * low stack */
const PTR_SIZE: usize = 8; /* Rust won't let me use size_of::<usize>() here because it's not defined as aconst */
const LOW_PAGE_STACK_PHYS_START: usize = 4 * 1024 * 1024;
const HIGH_PAGE_STACK_PHYS_START: usize = LOW_PAGE_STACK_PHYS_START + 
                                          ((STACK_SPLIT_PHYS_ADDR / physmem::SMALL_PAGE_SIZE) * PTR_SIZE);

/* create a system-wide stack for lowest 1GB of phys RAM with a locking mechanism. */
static LOWSTACK: Mutex<PageStack> = Mutex::new(PageStack
                                    {
                                        base: LOW_PAGE_STACK_PHYS_START,
                                        ptr: 0,
                                        max_ptr: 0,
                                        size: 0,
                                        virtual_translation_offset: 0,
                                    });

/* create a system-wide stack for >1GB of phys RAM with a locking mechanism. */
static HIGHSTACK: Mutex<PageStack> = Mutex::new(PageStack
                                     {
                                        base: HIGH_PAGE_STACK_PHYS_START,
                                        ptr: 0,
                                        max_ptr: 0,
                                        size: 0,
                                        virtual_translation_offset: 0,
                                     });

/* individual page stack design notes
 *
 * Each 1GB of physical RAM takes up 2MB of RAM: 262,144 x 8-byte pointers.
 * Each stacked pointer is the base address of a 4K physical page frame.
 * Pop the stack to obtain a pointer to an available 4K physical page.
 * Push the stack to return a 4K physical page for reuse.
 *
 * Start stack at the 4MB mark in physical RAM. Consider a sub-stack per CPU core?
 *
 * We force Rust to give stack_base a fixed kernel address, pointing to the
 * base of the stack (natch). We then manipulate the memory aboveit using
 * .offset(). stack_ptr is the offset to the first empty slot, so 0 means an
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
    base: usize,     /* base physical address of this stack */
    max_ptr: usize,  /* ptr cannot be greater than stack_max */ 
    ptr: usize,      /* index into the stack, start form zero at the base */
    size: usize,     /* total size of the stack in memory in bytes */

    /* when we need to convert a physical RAM address to a kernel virtual
     * address, allowing the kernel to use the address as a pointer,
     * add virtual_translation_offset to the physical address.
     * at boot this is zero, but eventually all the kernel's physical
     * memory accesses occur in the upper kernel memory area. */
    virtual_translation_offset: usize,
}

impl PageStack
{
    /* phys_to_kernel_virt
     *
     * Convert a physical RAM address to a kernel virtual address.
     * The kernel eventually maps all of physical memory into an
     * upper kernel-only space. All physical memory accesses must
     * happen in this high virtual area. This function converts
     * physical addresses into kernel-accessible virtual addresses.
     * => phys = physical address to translate
     * <= returns kernel virtual address
     */
    fn phys_to_kernel_virt(&self, phys: usize) -> usize
    {
        phys + self.virtual_translation_offset
    }

    /* set_kernel_translation_offset
     *
     * Set the offset used to translate physical RAM addresses into
     * kernel-accessible virtual addresses. See phys_to_kernel_virt()
     * for more info.
     * => offset = value added to physical addresses to translate
     *             them into kernel virtual adddresses.
     */
    pub fn set_kernel_translation_offset(&mut self, offset: usize)
    {
        self.virtual_translation_offset = offset;
    }

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

    /* return true if addr falls within the physical address range of the
     * page stack, or false if not. needed to ensure we don't reuse physical
     * memory already in use by the page stack. */
    pub fn check_collision(&mut self, addr: usize) -> bool
    {
        if addr >= self.base && addr < (self.base + self.size) { return true; }

        false
    }

    /* push
     *
     * Stash a 4K page's physical address on top of the stack and increment
     * the stack pointer. The address must be 4K aligned and the stack
     * must not be full.
     * => phys_addr = physical address to push onto the stack
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
        if phys_addr & (physmem::SMALL_PAGE_SIZE - 1) != 0
        {
            return Err(KernelInternalError::BadPhysPgAddress);
        }
            
        /* calculate the virtual address we need to write to in the stack,
         * write to it, and increment the stack pointer */
        unsafe{ ptr::write(self.ptr_to_kernel_addr() as *mut _, phys_addr); }

        self.ptr = self.ptr + 1;
        Ok(())
    }

    /* pop
     *
     * Pop a 4K page's base physical address off the stack, if available.
     * <= returns address or error code on failure.
     */
    pub fn pop(&mut self) -> Result<usize, KernelInternalError>
    {
        /* bail out if there are no physical pages available (gulp) */
        if self.ptr == 0
        {
            return Err(KernelInternalError::NoPhysPgAvailable)
        }

        /* decrement the ptr, get the physical page address from the stack,
         * and then zero the stack entry. use virtual addresses to access
         * the stack. */
        self.ptr = self.ptr - 1;
        let ptr_addr = self.ptr_to_kernel_addr();
        
        let pg_addr = unsafe{ ptr::read(ptr_addr as *mut _) };

        unsafe{ ptr::write(ptr_addr as *mut _, 0); }

        Ok(pg_addr)
    }

    /* ptr_to_kernel_addr
     *
     * Calculate the kernel virtual address of the stack entry for the current ptr
     * so it can be used to access that particular stack entry.
     * <= returns kernel virtual address for the stack ptr entry
     */
    fn ptr_to_kernel_addr(&mut self) -> usize
    {
        self.phys_to_kernel_virt(self.base + (self.ptr * size_of::<usize>()))
    }
}

/* ----------------------------------------------------------------------- */

/* veneer of functions to provide access to LOWSTACK and HIGHSTACK.
 * check the function definitions in PageStack for full details of their use. */

/* set the kernel phys->virt translation offset for the stacks */
pub fn set_kernel_translation_offset(offset: usize)
{
    /* will always succeed - it's just integer math */
    LOWSTACK.lock().set_kernel_translation_offset(offset);
    HIGHSTACK.lock().set_kernel_translation_offset(offset);
}

/* set limits for the page stacks: limit = max number of stack entries */
pub fn set_limit(limit: usize) -> Result<(), KernelInternalError>
{
    let page_split = STACK_SPLIT_PHYS_ADDR / physmem::SMALL_PAGE_SIZE;
    let mut lower: usize = 0;
    let mut upper: usize = 0;

    if limit > page_split
    {
        lower = page_split;
        upper = limit - page_split;
    }
    else
    {
        lower = limit;
    }

    try!(LOWSTACK.lock().set_limit(lower));
    try!(HIGHSTACK.lock().set_limit(upper));
    Ok(())
}

/* returns true if the given physical address is occupied by a page stack */
pub fn check_collision(addr: usize) -> bool
{
    if LOWSTACK.lock().check_collision(addr) == true
    {
        /* don't bother checking HIGHSTACK if LOWSTACK collides */
        return true;
    }

    return HIGHSTACK.lock().check_collision(addr);
}

/* push a 4K physical page base address onto the correct stack */
pub fn push(phys_addr: usize) -> Result<(), KernelInternalError>
{
    /* make sure we return the page to the correct stack */
    if phys_addr < STACK_SPLIT_PHYS_ADDR
    {
        try!(LOWSTACK.lock().push(phys_addr));
        return Ok(());
    }

    try!(HIGHSTACK.lock().push(phys_addr));
    Ok(())
}

/* pop a 4K page's base physical address off the stack */
pub fn pop() -> Result<usize, KernelInternalError>
{
    /* try the low stack then the high stack */
    let res = LOWSTACK.lock().pop();
    if res.is_ok() == true { return res; }

    return HIGHSTACK.lock().pop();
}

