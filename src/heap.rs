/*
 * diosix microkernel 'menchi'
 *
 * Provide dynamic memory allocation for the kernel
 *
 * Maintainer: Chris Williams (diosix.org)
 *
 */

use errors::KernelInternalError;
use ::hardware::physmem;

use spin::Mutex;
use core::ptr;
use core::mem::size_of;

/* heap design notes
 *
 * Plan is to use a fixed-block allocator - not because it's trivial
 * but because this microkernel is likely to allocate memory for a
 * small set of structures - control blocks for process, thread,
 * compartment, and interrupt management. we'll start with blocks
 * of 32 bytes, and use the diagnostic stats to figure out if this
 * needs changing. 32 bytes is nice because 128 x 32-byte blocks 
 * fits inside a 4096-byte page, and the header will take up 32
 * bytes too.
 *
 * One worry is fragmentation, with small blocks trapped between
 * groups of blocks.
 *
 * Blocks are grouped into allocations, which are tracked using
 * a double-linked list. When an allocation is requested, we
 * scan the free pool for a block, or group of blocks, and
 * hopefully remove one from the pool and return that address.
 * If we can't find a suitable block, grab a 4K page of memory, 
 * take the block from the first part of the page, and then 
 * add the rest of the page to the free pool.
 *
 * If you need more than 4064 bytes (4096 - header size) then
 * just ask for a page from the system.
 *
 */

const BLOCK_SIZE:       usize = 32;
const BLOCK_MAGIC_IN_USE: u64 = 0x4c69766548656170; /* LiveHeap */
const BLOCK_MAGIC_FREE:   u64 = 0x4465616448656170; /* DeadHeap */

/* there are 128 x 32-byte blocks in a 4K page, minus one for the header */
const BLOCKS_PER_PAGE:  usize = (::hardware::physmem::SMALL_PAGE_SIZE / BLOCK_SIZE) - 1;

pub static KERNEL: Mutex<Heap> = Mutex::new(Heap
                                    {
                                        free: 0 as *mut _,
                                        blocks_in_use:     0,
                                        free_pool_blocks:  0,
                                        bytes_in_use:      0,
                                        free_pool_bytes:   0,
                                        total_allocated:   0,
                                        total_allocations: 0,
                                    });

pub struct Heap
{
    /* pointer to free list */
    free: *mut HeapAllocation,

    /* usage stats - not including allocations' headers */
    blocks_in_use: usize, /* blocks in use right now */
    free_pool_blocks: usize, /* blocks sitting in the free pool */
    bytes_in_use: usize, /* bytes in use right now */
    free_pool_bytes: usize, /* bytes in the free pool right now */

    /* diagnostic stats so we can calculate the
     * average size of the kernel's allocs. */
    total_allocated: usize, /* running total of bytes allocated */
    total_allocations: usize, /* running total of alloc requests */
}

pub struct HeapAllocation
{
    magic: u64, /* must be BLOCK_MAGIC_IN_USE or BLOCK_MAGIC_FREE */
    blocks: usize, /* number of blocks in this allocation not including the header */

    /* linked list pointers for the free list */
    previous: *mut HeapAllocation,
    next: *mut HeapAllocation,
}

/* wrap a nice interface around the default KERNEL heap */
pub fn init() -> Result<(), KernelInternalError>
{
    try!(KERNEL.lock().init());
    Ok(())
}

macro_rules! kalloc
{
    ($size:expr) => ($crate::heap::KERNEL.lock().alloc($size))
}

macro_rules! kalloc_debug
{
    () => ($crate::heap::KERNEL.lock().debug_stats())
}

impl Heap
{
    /* init
     *
     * Initialize the heap by priming it with some free memory. Must be called first
     * before other Heap functions.
     * <= error code on failure.
     */
    pub fn init(&mut self) -> Result<(), KernelInternalError>
    {
        /* grab a page to add to the free list to get us started */
        let mut free_block: *mut HeapAllocation = ptr::null_mut();
        free_block = try!(::hardware::physmem::get_page()) as *mut _;

        unsafe
        {
            (*free_block).magic    = BLOCK_MAGIC_FREE;
            (*free_block).blocks   = BLOCKS_PER_PAGE;
            (*free_block).previous = ptr::null_mut();
            (*free_block).next     = ptr::null_mut();
        }
        
        self.free = free_block;
        self.free_pool_bytes = BLOCKS_PER_PAGE * BLOCK_SIZE;
        self.free_pool_blocks = BLOCKS_PER_PAGE;

        Ok(())
    }

    /* alloc
     *
     * Allocate some memory for the kernel.
     * => size = bytes to allocate
     * <= pointer to memory, or an error code on failure.
     */
    pub fn alloc(&mut self, size: usize) -> Result<*mut u8, KernelInternalError>
    {
        let mut blocks_req: usize = size / BLOCK_SIZE;
        if(size % BLOCK_SIZE) > 0
        {
            blocks_req = blocks_req + 1; /* round up to nearest whole block */
        }

        /* inspect the free list for a suitable block */


        /* the easy part - fill out the statistics */
        self.blocks_in_use = self.blocks_in_use + blocks_req;
        self.bytes_in_use = self.bytes_in_use + size;
        self.total_allocations = self.total_allocations + 1;
        self.total_allocated = self.total_allocated + size;

        Ok(0 as *mut _)
    }

    pub fn debug_stats(&self)
    {
        if self.total_allocations == 0
        {
            kprintln!("[mem] kernel heap statistics: nothing to report");
            return;
        }

        kprintln!("[mem] kernel heap statistics:");
        kprintln!("... {} bytes allocated in {} blocks", self.bytes_in_use, self.blocks_in_use);
        kprintln!("... {} bytes in free pool in {} blocks", self.free_pool_bytes, self.free_pool_blocks);
        kprintln!("... {} allocation rquests, average block size is {} bytes",
                  self.total_allocations, self.total_allocated / self.total_allocations);
    }
}

