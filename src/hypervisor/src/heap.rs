/* diosix heap management
 *
 * Simple heap manager. A CPU can allocate only from its own
 * heap pool, though it can share these pointers with any CPU.
 * Any CPU can free them back to the owner's heap pool when
 * they are done with these allocations.
 * 
 * Thus this code is *single threaded* per individual CPU core
 * and also lock-free.
 * 
 * Each CPU heap is primed with a small amount of fixed
 * physical RAM, defined by the platform code. When this
 * fixed pool runs low, the heap code requests a temporary
 * block of memory from the physical memory manager. 
 * this block is added as a free block to the heap and
 * subsequently allocated from.
 *  
 * We use Rust's memory safety features to prevent any
 * use-after-free(). Blocks are free()'d atomically
 * preventing any races.
 * 
 * This code interfaces with Rust's global allocator API
 * so things like vec! and Box just work. Heap is
 * the underlying engine for HVallocator.
 * 
 * (c) Chris Williams, 2019-2021.
 *
 * See LICENSE for usage and copying.
 */

use core::alloc::{GlobalAlloc, Layout};
use core::ptr::null_mut;
use core::mem;
use core::fmt;
use core::result::Result;
use core::sync::atomic::{AtomicUsize, Ordering};
use platform::physmem::{PhysMemSize, PhysMemBase};
use super::physmem::{self, alloc_region, RegionHygiene};
use super::error::Cause;

/* different states each recognized heap block can be in */
#[derive(PartialEq, Debug, Clone, Copy)]
enum HeapMagic
{
    Free     = 0x0deadded,
    InUse    = 0x0d10c0de,
    BadMagic = 0xabad1dea
}

impl HeapMagic
{
    pub fn from_usize(value: usize) -> Self
    {
        match value
        {
            0x0deadded => Self::Free,
            0x0d10c0de => Self::InUse,
            _ => Self::BadMagic
        }
    }
}

/* source of a heap block */
#[derive(PartialEq, Debug, Clone, Copy)]
enum HeapSource
{
    Fixed,      /* allocated during startup by platform code */
    Temporary   /* allocated dynamically from physical memory pool */
}

/* to avoid fragmentation, allocate in block sizes of this multiple, including header */
const HEAP_BLOCK_SIZE: usize = 128;

/* follow Rust's heap allocator API so we can drop our per-CPU allocator in and use things
like Box. We allow the Rust toolchain to track and check pointers and object lifetimes,
while we'll manage the underlying physical memory used by the heap. */
pub struct HVallocator;

unsafe impl GlobalAlloc for HVallocator
{
    unsafe fn alloc(&self, layout: Layout) -> *mut u8
    {
        let bytes = layout.size();

        match (*<super::pcore::PhysicalCore>::this()).heap.alloc::<u8>(bytes)
        {
            Ok(p) => p,
            Err(e) =>
            {
                hvalert!("HVallocator: request for {} bytes failed ({:?})", bytes, e);
                null_mut() /* yeesh */
            }
        }
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout)
    {
        match (*<super::pcore::PhysicalCore>::this()).heap.free::<u8>(ptr)
        {
            Err(e) =>
            {
                hvalert!("HVallocator: request to free {} bytes at {:p} failed ({:?})", layout.size(), ptr, e)
            },
            _ => ()
        }
    }
}

/* describe the layout of a per-CPU heap block */
#[repr(C)]
pub struct HeapBlock
{
    /* heap is a single-link-list to keep it simple and safe */
    next: Option<*mut HeapBlock>,
    /* size of this block *including* header */
    size: PhysMemSize,
    /* define block state using magic words */
    magic: AtomicUsize,
    /* define the source of the memory */
    source: HeapSource
    /* block contents follows... */
}

/* this is our own internal API for the per-CPU hypervisor heap. use high-level abstractions, such as Box,
rather than this directly, so we get all the safety measures and lifetime checking. think of kallocator
as the API and Heap as the engine. kallocator is built on top of Heap, and each CPU core has its own Heap. */
#[repr(C)]
pub struct Heap
{
    /* pointer to list of in-use and freed blocks */
    block_list_head: *mut HeapBlock,
    /* stash a copy of the block header size here */
    block_header_size: PhysMemSize,
}

/* describe a heap by its totals */
pub struct HeapStats
{
    pub free_total: usize,      /* total free space in bytes */
    pub alloc_total: usize,     /* total bytes allocated */
    pub largest_free: usize,    /* largest single free block in bytes */
    pub largest_alloc: usize    /* largest allocated block in bytes */
}

/* pretty print the heap's stats */
impl fmt::Debug for Heap
{
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result
    {
        let stats = self.calculate_stats();

        write!(f, "size: {} alloc'd {} free {} largest alloc'd {} largest free {}",
            stats.alloc_total + stats.free_total,
            stats.alloc_total, stats.free_total,
            stats.largest_alloc, stats.largest_free)
    }
}

/* clean up heap list by returning chunks of free temporary physical RAM */
macro_rules! heaphousekeeper
{
    () => ((*<super::pcore::PhysicalCore>::this()).heap.return_unused();)
}

impl Heap
{
    /* initialize this heap area. start off with one giant block
    covering all of free space, from which other blocks will be carved.
    this initial block is assuemd to be a fixed platform-allocated area
    of physical memory.
    => start = pointer to start of heap area
       size = number of available bytes in heap */
    pub fn init(&mut self, start: *mut HeapBlock, size: PhysMemSize)
    {
        /* start with a free block covering the available space */
        unsafe
        {
            let block = start;
            (*block).size = size;
            (*block).next = None;
            (*block).magic = AtomicUsize::new(HeapMagic::Free as usize);
            (*block).source = HeapSource::Fixed;

            self.block_header_size = mem::size_of::<HeapBlock>();
            self.block_list_head = block;
        }
    }

    /* insert a free physical memory block at the head of the list
    => base = base address of the memory block to add
       size = total size of the block, including header that will be automatically added
    <= OK or error code */
    pub fn insert_free(&mut self, base: PhysMemBase, size: PhysMemSize) -> Result<(), Cause>
    {
        unsafe
        {
            /* craft free block from scratch */
            let block = base as *mut HeapBlock;
            (*block).size = size;
            (*block).next = Some(self.block_list_head);
            (*block).magic = AtomicUsize::new(HeapMagic::Free as usize);
            (*block).source = HeapSource::Temporary;

            /* add the free block to the start of the list */
            self.block_list_head = block;
        }

        Ok(())
    }

    /* free a previously allocated block
    => to_free = pointer previously returned by alloc()
    <= OK or failure code */
    pub fn free<T>(&mut self, to_free: *mut T) -> Result<(), Cause>
    {
        /* convert this into a raw pointer so we can find the heap block header */
        let mut ptr = to_free as usize;
        ptr = ptr - self.block_header_size;
        let block = ptr as *mut HeapBlock;
        
        unsafe
        {
            /* we should be the only one writing to this metadata, though there
            will be readers, hence the split in reading and writing */
            match HeapMagic::from_usize((*block).magic.load(Ordering::SeqCst))
            {
                HeapMagic::InUse =>
                {
                    (*block).magic.store(HeapMagic::Free as usize, Ordering::SeqCst);
                    Ok(())
                },
                /* if it's not in use, or bad magic, then bail out */
                HeapMagic::Free => Err(Cause::HeapNotInUse),
                HeapMagic::BadMagic => Err(Cause::HeapBadMagic)
            }
        }
    }

    /* allocate memory for the given object type. the returned pointer skips
    the heap block header, pointing to the available space,
    just like malloc() on other platforms.
    => T = type of object to allocate memory for
       num = number of objects to allocate for
    <= pointer to memory, or error code */
    pub fn alloc<T>(&mut self, num: usize) -> Result<*mut T, Cause>
    {
        if num == 0
        {
            return Err(Cause::HeapBadSize);
        }

        let mut done = false;
        let mut extended = false;

        /* calculate size of block required, including header, rounded up to
        nearest whole heap block multiple */
        let mut size_req = (mem::size_of::<T>() * num) + self.block_header_size;
        size_req = ((size_req / HEAP_BLOCK_SIZE) + 1) * HEAP_BLOCK_SIZE;

        /* scan all blocks for first free fit */
        let mut search_block = self.block_list_head;
        unsafe
        {
            while !done
            {
                if HeapMagic::from_usize((*search_block).magic.load(Ordering::SeqCst)) == HeapMagic::Free && (*search_block).size >= size_req
                {
                    /* we've got a winner. if the found block is equal size, or only a few bytes
                    larger than the required size, then take the whole block */
                    if ((*search_block).size - size_req) < HEAP_BLOCK_SIZE
                    {
                        (*search_block).magic.store(HeapMagic::InUse as usize, Ordering::SeqCst);
                        let found_ptr = (search_block as usize) + self.block_header_size;
                        return Result::Ok(found_ptr as *mut T);
                    }
                    else
                    {
                        /* carve the end of a large-enough free block off to make a new block.
                        then add this new block to the start of the list */
                        (*search_block).size = (*search_block).size - size_req;
                        
                        /* skip to the new (shorter) end of the free block */
                        let mut found_ptr = (search_block as usize) + (*search_block).size;

                        /* set metadata for newly allocated block */
                        let alloc_block = found_ptr as *mut HeapBlock;
                        (*alloc_block).next  = Some(self.block_list_head);
                        (*alloc_block).magic.store(HeapMagic::InUse as usize, Ordering::SeqCst);
                        (*alloc_block).size  = size_req;

                        /* point the head of the list at new block */
                        self.block_list_head = alloc_block;

                        /* adjust pointer to skip the header of our new block, and we're done */
                        found_ptr = found_ptr + self.block_header_size;
                        return Result::Ok(found_ptr as *mut T);
                    }
                }

                /* make sure we don't run off the end of the list.
                also, attempt to consolidate neighboring blocks to make
                more bytes available and reduce fragmentation. do this 
                after we've tried searching for available blocks */
                match (*search_block).next
                {
                    None => if self.consolidate() < HEAP_BLOCK_SIZE
                    {
                        if extended == false
                        {
                            /* if we can't squeeze any more bytes out of the list
                            then grab a chunk of available RAM from the physical
                            memory manager and add it to the free list */
                            let region = match alloc_region(size_req)
                            {
                                Ok(r) => r,
                                Err(_e) =>
                                {
                                    /* give up and bail out if there's no more physical memory */
                                    hvdebug!("Failed to extend heap by {} bytes: {:?}", size_req, _e);
                                    return Result::Err(Cause::HeapNoFreeMem);
                                }
                            };

                            if self.insert_free(region.base(), region.size()).is_ok()
                            {
                                extended = true;

                                /* start the search over, starting with the new block */
                                search_block = self.block_list_head;
                            }
                            else
                            {
                                /* if we couldn't insert free block, give up */
                                done = true;
                            }
                        }
                        else
                        {
                            /* can't squeeze any more out of list and we've tried allocating more
                            physical memory. give up at this point, though we shouldn't really
                            end up here */
                            hvdebug!("Giving up allocating {} bytes", size_req);
                            done = true;
                        }
                    }
                    else
                    {
                        /* start the search over */
                        search_block = self.block_list_head;
                    },
                    Some(n) => search_block = n
                };
            }
        }

        return Result::Err(Cause::HeapNoFreeMem);
    }

    /* deallocate any free temporary physical memory regions that are no longer needed */
    pub fn return_unused(&mut self)
    {
        /* ensure all blocks are gathered up */
        loop
        {
            if self.consolidate() < HEAP_BLOCK_SIZE
            {
                break;
            }
        }

        /* search for unused physical memory blocks to return */
        let mut block = self.block_list_head;
        let mut prev_block: Option<*mut HeapBlock> = None;
        unsafe
        {
            loop
            {
                match ((*block).source, HeapMagic::from_usize((*block).magic.load(Ordering::SeqCst)))
                {
                    /* remove physical region from single-linked list if successfully deallocated.
                    the physical memory manager will avoid fragmentation by rejecting regions that
                    are not multiples of prefered region sizes */
                    (HeapSource::Temporary, HeapMagic::Free) =>
                    {
                        let region = physmem::Region::new(block as PhysMemBase, (*block).size, RegionHygiene::CanClean);
                        if physmem::dealloc_region(region).is_ok()
                        {
                            hvdebug!("Returning heap block {:p} size {} to physical memory pool",
                            block, (*block).size);

                            /* delink the block - do not touch the contents of the
                            deallocated block: it's back in the pool and another CPU core
                            could grab it at any time. After dealloc_region() returns Ok,
                            it's gone as far as this core is concerned. */
                            match prev_block
                            {
                                Some(b) => (*b).next = (*block).next,
                                None => ()
                            };
                        }
                    },

                    (_, _) => ()
                }

                match (*block).next
                {
                    Some(n) =>
                    {
                        prev_block = Some(block);
                        block = n;
                    }
                    None => break
                };
            }
        }
    }

    /* pass once over the heap and try to merge adjacent free blocks
    <= size of the largest block seen, in bytes including header */
    fn consolidate(&mut self) -> PhysMemSize
    {
        let mut largest_merged_block: PhysMemSize = 0;

        let mut block = self.block_list_head;
        unsafe
        {
            /* can't merge if we're the last block in the list */
            while (*block).next.is_some()
            {
                let next = (*block).next.unwrap();
                if HeapMagic::from_usize((*block).magic.load(Ordering::SeqCst)) == HeapMagic::Free &&
                    HeapMagic::from_usize((*next).magic.load(Ordering::SeqCst)) == HeapMagic::Free
                {
                    let target_ptr = (block as usize) + (*block).size;
                    if target_ptr == next as usize
                    {
                        /* we're adjacent, we're both free, and we can merge */
                        let merged_size = (*block).size + (*next).size;
                        if merged_size > largest_merged_block
                        {
                            largest_merged_block = merged_size;
                        }
                        (*block).size = merged_size;
                        (*block).next = (*next).next;
                    }
                }
                match (*block).next
                {
                    Some(n) => block = n,
                    None => break,
                };
            }

            /* catch corner case of there being two free blocks: the first on the
            list is higher than the last block on the list, and they are both free */
            if HeapMagic::from_usize((*self.block_list_head).magic.load(Ordering::SeqCst)) == HeapMagic::Free
            {
                match (*self.block_list_head).next
                {
                    Some(next) =>
                    {
                        if HeapMagic::from_usize((*next).magic.load(Ordering::SeqCst)) == HeapMagic::Free
                        {
                            if (next as usize) + (*next).size == self.block_list_head as usize
                            {
                                (*next).size = (*next).size + (*self.block_list_head).size;
                                self.block_list_head = next;
                                if (*next).size > largest_merged_block
                                {
                                    largest_merged_block = (*next).size;
                                }
                            }
                        }
                    },
                    _ => ()
                }
            }
        }

        return largest_merged_block;
    }

    /* generate a block of statistics describing the heap */
    pub fn calculate_stats(&self) -> HeapStats
    {
        let mut free_total = 0;
        let mut alloc_total = 0;
        let mut largest_free = 0;
        let mut largest_alloc = 0;

        let mut done = false;
        let mut block = self.block_list_head;
        unsafe
        {
            while !done
            {
                let size = (*block).size;
                match HeapMagic::from_usize((*block).magic.load(Ordering::SeqCst))
                {
                    HeapMagic::InUse =>
                    {
                        alloc_total = alloc_total + size;
                        if size > largest_alloc
                        {
                            largest_alloc = size;
                        }
                    },
                    HeapMagic::Free =>
                    {
                        free_total = free_total + size;
                        if size > largest_free
                        {
                            largest_free = size;
                        }
                    },
                    HeapMagic::BadMagic => hvdebug!("Bad magic for heap block {:p} during audit", block)
                };

                match (*block).next
                {
                    None => done = true,
                    Some(b) => block = b
                };
            }
        }

        HeapStats
        {
            free_total,
            alloc_total,
            largest_alloc,
            largest_free
        }
    }
}
