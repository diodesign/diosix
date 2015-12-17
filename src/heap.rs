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

const BLOCK_NULL_PTR: *mut HeapAllocation = 0 as *mut HeapAllocation;

pub static KERNEL: Mutex<Heap> = Mutex::new(Heap
                                    {
                                        free:                  BLOCK_NULL_PTR,
                                        blocks_in_use:         0,
                                        allocations_in_use:    0,
                                        free_pool_blocks:      0,
                                        total_bytes_requested: 0,
                                        total_alloc_requests:  0,
                                    });

pub struct Heap
{
    /* pointer to head of the free list */
    free: *mut HeapAllocation,

    /* usage stats - not including allocations' headers */
    blocks_in_use: usize, /* blocks in use right now */
    free_pool_blocks: usize, /* blocks sitting in the free pool */
    allocations_in_use: usize, /* number of allocations */

    /* diagnostic stats so we can calculate the
     * average size of the kernel's allocs. */
    total_bytes_requested: usize, /* running total of bytes allocated */
    total_alloc_requests: usize, /* running total of allocatio requests */
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

macro_rules! kfree
{
    ($addr:expr) => ($crate::heap::KERNEL.lock().free($addr))
}

impl Heap
{
    /* top_up_free_pool
     *
     * Add a page of RAM to the pool to provide some free blocks.
     * <= returns an error code on failure.
     */
    fn top_up_free_pool(&mut self) -> Result<(), KernelInternalError>
    {
        /* grab a page to add to the free list to get us started */
        let free_block = try!(::hardware::physmem::get_page());
       
        /* the page is headerless, so add it using add_raw_mem_to_free(),
         * which gives us a count of usable blocks in the memory area. */
        let block_count = self.add_raw_mem_to_free(free_block, ::hardware::physmem::SMALL_PAGE_SIZE);
        self.free_pool_blocks = self.free_pool_blocks + block_count;
        
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

        /* calculate nr of blocks required to fulfill this alocation request,
         * not including the header */
        let mut blocks_req: usize = size / BLOCK_SIZE;
        if(size % BLOCK_SIZE) > 0
        {
            blocks_req = blocks_req + 1; /* round up to nearest whole block */
        }

        /* start search for suitable group of free block(s) to fulfill request */
        let mut found = self.free; /* search forward through the free list */
        let mut found_blocks = 0; /* size of found block */

        /* make two passes: first time looking at the free pool, and
         * second time after priming the pool with new blocks */
        for attempts in 0..2
        {
            /* inspect the free list for a suitable block or group of blocks */
            loop
            {
                /* give up when we hit a null pointer */
                if found == BLOCK_NULL_PTR { break; }
            
                unsafe
                {
                    /* sanity check */
                    if (*found).magic != BLOCK_MAGIC_FREE
                    {
                        kprintln!("[mem] BUG! Non-free heap block {:p} in free pool (magic = {:x})", found, (*found).magic);
                        return Err(KernelInternalError::HeapCorruption);
                    }

                    /* is this allocation of free block(s) big enough for the request? */
                    found_blocks = (*found).blocks;
                    if found_blocks >= blocks_req { break; }

                    /* try the next block if the group of free block(s) wasn't big enough */
                    found = (*found).next;
                }
            }

            /* end the search if we've found a suitable group of block(s) */
            if found != BLOCK_NULL_PTR { break; }

            /* if we're still here, reflll the pool and try again */
            try!(self.top_up_free_pool());
            found = self.free;
        }

        /* if we're still drawing dead, then bail out - the request is probably too big */
        if found == BLOCK_NULL_PTR { return Err(KernelInternalError::HeapBadAllocReq); }

        /* detach the found group of block(s) from the free list */
        unsafe
        {
            /* remove from head of the linked list */
            if self.free == found
            {
                self.free = (*found).next;
            }
            
            /* connect the previous block in the chain to the next block */
            let mut previous = (*found).previous;
            if previous != BLOCK_NULL_PTR
            {
                (*previous).next = (*found).next;
                (*found).previous = BLOCK_NULL_PTR;
            }

            /* connect the next block in the chain to the previous block */
            let mut next = (*found).next;
            if next != BLOCK_NULL_PTR
            {
                (*next).previous = previous;
                (*found).next = BLOCK_NULL_PTR;
            }

            /* update block metadata */
            (*found).magic = BLOCK_MAGIC_IN_USE;
            (*found).blocks = blocks_req;
        }

        /* we may have to split a group of blocks: snap off the unneeded part of the 
         * group and put it back into the free pool with a new header. the current
         * header has been repurposed for the allocated block(s). */
        if found_blocks > blocks_req
        {
            let split_addr = (found as usize) + HEADER_SIZE + (blocks_req * BLOCK_SIZE);
            self.free_pool_blocks = self.free_pool_blocks - found_blocks;
            let added_blocks = self.add_raw_mem_to_free(split_addr, (found_blocks - blocks_req) * BLOCK_SIZE);
            self.free_pool_blocks = self.free_pool_blocks + added_blocks;
        }
        
        /* the easy part: update the accounting */
        self.blocks_in_use = self.blocks_in_use + blocks_req;
        self.allocations_in_use = self.allocations_in_use + 1;
        self.total_alloc_requests = self.total_alloc_requests + 1;
        self.total_bytes_requested = self.total_bytes_requested + size;

        /* skip over the header when handing back a pointer */
        self.debug_stats(DebugOutput::Silent, DebugCheckPoint::Alloc);
        Ok(((found as usize) + HEADER_SIZE) as *mut _)
    }

    pub fn free(&mut self, addr: *mut u8) -> Result<(), KernelInternalError>
    {
        /* sanity checks */
        if addr == 0 as *mut _ { return Err(KernelInternalError::HeapBadFreeReq); }

        let header: *mut HeapAllocation = ((addr as usize) - HEADER_SIZE) as *mut _;
        let mut block_count = 0;

        unsafe
        {
            if (*header).magic != BLOCK_MAGIC_IN_USE
            {
                kprintln!("[mem] BUG! free() called with bad pointer {:p}", addr);
                return Err(KernelInternalError::HeapBadFreeReq);
            
            }

            block_count = (*header).blocks;
            
            /* decouple it from the list */
            if (*header).next != BLOCK_NULL_PTR
            {
                let mut next = (*header).next;
                (*next).previous = (*header).previous;
            }
            
            if (*header).previous != BLOCK_NULL_PTR
            {
                let mut previous = (*header).previous;
                (*previous).next = (*header).next;
            }

        }

        /* then just treat it as a block of raw memory that needs freeing */
        let size = (block_count * BLOCK_SIZE) + HEADER_SIZE;
        let blocks_freed = self.add_raw_mem_to_free(header as usize, size);

        /* update accounting */
        self.blocks_in_use = self.blocks_in_use - block_count;
        self.allocations_in_use = self.allocations_in_use - 1;
        self.free_pool_blocks = self.free_pool_blocks + blocks_freed;

        self.debug_stats(DebugOutput::Silent, DebugCheckPoint::Free);
        Ok(())
    }

    /* add_raw_mem_to_free
     *
     * Add a headerless-block (or group of them) to the free pool.
     * This does not update the heap's accounting variables because
     * add_to_free() may be called during a block split. It's up
     * to the caller to update the heap's accounting.
     * => ptr = address of start of block(s)
     *    size = number of bytes in group
     * <= number of usable blocks in size
     */
    fn add_raw_mem_to_free(&mut self, ptr: usize, size: usize) -> usize
    {
        let mut new = ptr as *mut HeapAllocation;
        let usable_blocks = (size - HEADER_SIZE) / BLOCK_SIZE;

        /* don't put an empty space into the free pool */
        if size == 0 { return 0; }

        unsafe
        {
            /* add a header */
            (*new).next = self.free;
            (*new).previous = BLOCK_NULL_PTR;
            (*new).blocks = usable_blocks;
            (*new).magic = BLOCK_MAGIC_FREE;

            /* make old head of the list point back to this new block */
            if self.free != BLOCK_NULL_PTR
            {
                let mut old_head = self.free;
                (*old_head).previous = new;
            }
            
            /* attach to head of the free list */
            self.free = new;
        }

        self.debug_stats(DebugOutput::Silent, DebugCheckPoint::AddRawMem);
        return usable_blocks;
    }


    pub fn debug_stats(&self, output: DebugOutput, checkpoint: DebugCheckPoint)
    {
        if output == DebugOutput::Verbose
        {
            if self.total_alloc_requests == 0
            {
                kprintln!("[mem] kernel heap statistics: nothing to report");
                return;
            }

            let checkpoint_text = match checkpoint
            {
                DebugCheckPoint::Alloc     => "alloc()",
                DebugCheckPoint::Free      => "free()",
                DebugCheckPoint::AddRawMem => "add_raw_mem_to_free()",
                DebugCheckPoint::Request   => "by kernel request",
            };

            kprintln!("------- debug checkpoint triggered in heap.rs {} -------------", checkpoint_text);
            kprintln!("[mem] kernel heap statistics:");
            
            kprintln!("... {} bytes in {} allocations, {} blocks in use, plus {} bytes overhead",
                      self.blocks_in_use * BLOCK_SIZE, self.allocations_in_use, self.blocks_in_use,
                      HEADER_SIZE * self.allocations_in_use);
            
            kprintln!("... {} bytes in free pool in {} blocks",
                      self.free_pool_blocks * BLOCK_SIZE, self.free_pool_blocks);
           
            kprintln!("... {} allocation requests in total, {} bytes requested, average request size is {} bytes",
                      self.total_alloc_requests, self.total_bytes_requested,
                      self.total_bytes_requested / self.total_alloc_requests);
        }

        /* walk the free list */
        if output == DebugOutput::Verbose
        {
            kprintln!("[mem] kernel heap free pool:");
        }
        let mut block = self.free;
        loop
        {
            if block == BLOCK_NULL_PTR { break; }
            unsafe
            {
                if output == DebugOutput::Verbose
                {
                    kprint!("... {} blocks [{:x} <--- {:x} --> {:x}] ",
                              (*block).blocks, (*block).previous as usize, block as usize, (*block).next as usize);
                }

                if (*block).magic == BLOCK_MAGIC_FREE
                {
                    if output == DebugOutput::Verbose
                    {
                        kprintln!("[good magic]");
                    }
                }
                else
                {
                    if output == DebugOutput::Verbose
                    {
                        kprintln!("[BAD MAGIC]");
                    }
                    else
                    {
                        self.debug_stats(DebugOutput::Verbose, checkpoint);
                        panic!("block magic is bad");
                    }
                }

                if (*block).previous == BLOCK_NULL_PTR && block != self.free
                {
                    if output == DebugOutput::Silent   
                    {
                        self.debug_stats(DebugOutput::Verbose, checkpoint);
                        panic!("block group previous pointer is NULL but is not free list head");
                    }
                }
                
                block = (*block).next;
            }
        }
    }
}

pub enum DebugCheckPoint
{
    AddRawMem,
    Free,
    Alloc,
    Request,
}

#[derive(PartialEq)]
pub enum DebugOutput
{
    Silent,
    Verbose
}

