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

const HEADER_SIZE:      usize = 32; /* can't use size_of here, it's 32 bytes */
const BLOCK_SIZE:       usize = 32; /* see above discussion for block size */
const BLOCK_MAGIC_IN_USE: u64 = 0x4c69766548656170; /* LiveHeap */
const BLOCK_MAGIC_FREE:   u64 = 0x4465616448656170; /* DeadHeap */

/* there are a maximum of 128 x 32-byte blocks in a 4K page, minus space for the header */
const BLOCKS_PER_PAGE:  usize = (::hardware::physmem::SMALL_PAGE_SIZE - HEADER_SIZE) / BLOCK_SIZE;

pub static KERNEL: Mutex<Heap> = Mutex::new(Heap
                                    {
                                        free: 0 as *mut _,
                                        blocks_in_use:     0,
                                        free_pool_blocks:  0,
                                        total_bytes_requested:   0,
                                        total_alloc_requests: 0,
                                    });

pub struct Heap
{
    /* pointer to free list */
    free: *mut HeapAllocation,

    /* usage stats - not including allocations' headers */
    blocks_in_use: usize, /* blocks in use right now */
    free_pool_blocks: usize, /* blocks sitting in the free pool */

    /* diagnostic stats so we can calculate the
     * average size of the kernel's allocs. */
    total_bytes_requested: usize, /* running total of bytes allocated */
    total_alloc_requests: usize, /* running total of alloc requests */
}

/* change HEADER_SIZE if you change this structure */
pub struct HeapAllocation
{
    magic: u64, /* must be BLOCK_MAGIC_IN_USE or BLOCK_MAGIC_FREE */
    blocks: usize, /* number of blocks in this allocation not including the header */

    /* linked list pointers for the free list */
    previous: *mut HeapAllocation,
    next: *mut HeapAllocation,
}

/* wrap a nice interface around the default KERNEL heap */
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
    /* top_up_free_pool
     *
     * Dump a page of RAM into the pool to provide some free blocks.
     * <= error code on failure.
     */
    fn top_up_free_pool(&mut self) -> Result<(), KernelInternalError>
    {
        /* grab a page to add to the free list to get us started */
        let free_block = try!(::hardware::physmem::get_page());
        
        self.add_to_free(free_block, ::hardware::physmem::SMALL_PAGE_SIZE);
        self.free_pool_blocks = self.free_pool_blocks + BLOCKS_PER_PAGE;

        Ok(())
    }

    /* alloc
     *
     * Allocate some memory for the kernel. This code is written defensively,
     * it can probably be optimized later if it proves to be a bottleneck.
     * => size = bytes to allocate from the heap. Must be non-zero.
     * <= pointer to memory, or an error code on failure.
     */
    pub fn alloc(&mut self, size: usize) -> Result<*mut u8, KernelInternalError>
    {
        if size == 0 { return Err(KernelInternalError::HeapBadAllocReq); }

        let mut blocks_req: usize = size / BLOCK_SIZE;
        if(size % BLOCK_SIZE) > 0
        {
            blocks_req = blocks_req + 1; /* round up to nearest whole block */
        }

        let mut block = self.free;
        let mut block_size = 0;

        /* make two passes: first time looking at the free pool, and
         * second time after priming the pool with new blocks */
        for attempts in 0..2
        {
            /* inspect the free list for a suitable block or group of blocks */
            loop
            {
                /* give up when we hit a null pointer */
                if block == 0 as *mut _ { break; }
            
                unsafe
                {
                    /* sanity check */
                    if (*block).magic != BLOCK_MAGIC_FREE
                    {
                        kprintln!("[mem] BUG! Non-free heap block {:p} in free pool", block);
                        return Err(KernelInternalError::HeapCorruption);
                    }

                    /* is this block big enough? */
                    block_size = (*block).blocks;
                    if block_size >= blocks_req { break; }

                    /* try the next block */
                    block = (*block).next;
                }
            }

            /* if we're coming up short in our search, reflll the pool and try again */
            if block == 0 as *mut _
            {
                try!(self.top_up_free_pool());
            }
            else
            {
                break;
            }

            block = self.free;
        }

        /* if we're still drawing dead, then bail out - the request is probably too big */
        if block == 0 as *mut _ { return Err(KernelInternalError::HeapBadAllocReq); }

        /* we may have to split a group of blocks */
        if block_size > blocks_req
        {
            let split_addr = (block as usize) + HEADER_SIZE + (blocks_req * BLOCK_SIZE);
            self.add_to_free(split_addr, (block_size - blocks_req) * BLOCK_SIZE);
        }

        /* detach the block from the free list */
        unsafe
        {
            /* remove from head of the linked list */
            if self.free == block
            {
                self.free = (*block).next;
            }
            
            /* connect the previous block in the chain to the next block */
            let mut previous = (*block).previous;
            if previous != 0 as *mut _
            {
                (*previous).next = (*block).next;
                (*block).previous = 0 as *mut _;
            }

            /* connect the next block in the chain to the previous block */
            let mut next = (*block).next;
            if next != 0 as *mut _
            {
                (*next).previous = (*block).previous;
                (*block).next = 0 as *mut _;
            }

            /* update block metadata */
            (*block).magic = BLOCK_MAGIC_IN_USE;
            (*block).blocks = blocks_req;
        }

        /* the easy part - fill out the statistics */
        self.blocks_in_use = self.blocks_in_use + blocks_req;
        self.total_alloc_requests = self.total_alloc_requests + 1;
        self.total_bytes_requested = self.total_bytes_requested + size;
        self.free_pool_blocks = self.free_pool_blocks - blocks_req;

        /* skip over the header when handing back a pointer */
        Ok(((block as usize) + HEADER_SIZE) as *mut _)
    }

    /* add_to_free
     *
     * Add a headerless-block (or group of them) to the free pool.
     * This does not update the heap's accounting variables because
     * add_to_free() may be called during a block split. It's up
     * to the caller to update the heap's accounting.
     * => ptr = address of start of block(s)
     *    size = number of bytes in group
     */
    fn add_to_free(&mut self, ptr: usize, size: usize)
    {
        let mut new = ptr as *mut HeapAllocation;
        let usable_blocks = (size - HEADER_SIZE) / BLOCK_SIZE;

        unsafe
        {
            /* add a header */
            (*new).next = self.free;
            (*new).previous = 0 as *mut _;
            (*new).blocks = usable_blocks;
            (*new).magic = BLOCK_MAGIC_FREE;

            /* attach to head of the free list */
            self.free = new;

            /* make old head of the list point back to this new block */
            if (*new).next != 0 as *mut _
            {
                let mut old_head = (*new).next;
                (*old_head).previous = new;
            }
        }
    }

    pub fn debug_stats(&self)
    {
        if self.total_alloc_requests == 0
        {
            kprintln!("[mem] kernel heap statistics: nothing to report");
            return;
        }

        kprintln!("[mem] kernel heap statistics:");
        kprintln!("... {} bytes allocated in {} blocks", self.blocks_in_use * BLOCK_SIZE, self.blocks_in_use);
        kprintln!("... {} bytes in free pool in {} blocks", self.free_pool_blocks * BLOCK_SIZE, self.free_pool_blocks);
        kprintln!("... {} allocation rquests, {} bytes requested, average request size is {} bytes",
                  self.total_alloc_requests, self.total_bytes_requested, self.total_bytes_requested / self.total_alloc_requests);

        /* walk the free list */
        kprintln!("[mem] kernel heap free pool:");
        let mut block = self.free;
        loop
        {
            if block == 0 as *mut _ { break; }
            unsafe
            {
                kprint!("... {} blocks [previous {:x} next {:x}] ",
                          (*block).blocks, (*block).previous as usize, (*block).next as usize);
                if (*block).magic == BLOCK_MAGIC_FREE
                {
                    kprintln!("[good magic]");
                }
                else
                {
                    kprintln!("[BAD MAGIC]");
                }

                block = (*block).next;
            }
        }
    }
}

