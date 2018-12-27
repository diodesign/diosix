/* diosix heap management
 *
 * Simple heap manager that is lock-free for free()
 * but requires a lock to alloc(), or only allow
 * one allocator and multiple free()ers per heap.
 * For exsmple: a per-CPU heap in which the owner
 * CPU can allocate from its own heap pool, and
 * share these pointers with any CPU, and any
 * CPU can free back to the owner's heap pool.
 *  
 * Interfaces with Rust's global allocator API
 * so things like vec! and Box work. Heap is
 * the underlying engine for kAllocator.
 * 
 * (c) Chris Williams, 2018.
 *
 * See LICENSE for usage and copying.
 */

use core::alloc::{GlobalAlloc, Layout};
use core::ptr::null_mut;

use core::mem;
use core::result::Result;
use ::error::Cause;

/* different states each recognized heap block can be in */
#[derive(PartialEq, Debug)]
#[repr(C)]
enum HeapMagic
{
    Free = 0x0deadded,
    InUse = 0x0d10c0de
}

/* to avoid fragmentation, allocate in block sizes of this multiple, including header */
const HEAP_BLOCK_SIZE: usize = 64;

/* follow Rust's heap allocator API so we can drop our per-CPU allocator in and use things
like Box. We allow the Rust toolchain to track and check pointers and object lifetimes,
while we'll manage the underlying physical memory used by the heap. */
pub struct Kallocator;

unsafe impl GlobalAlloc for Kallocator
{
    unsafe fn alloc(&self, layout: Layout) -> *mut u8
    {
        let bytes = layout.size();
        match (*<::cpu::Core>::this()).heap.alloc::<u8>(bytes)
        {
            Ok(p) => 
            {
                klog!("heap: allocating {:p}, {} bytes", p, bytes);
                p
            },
            Err(e) =>
            {
                kalert!("Kallocator: request for {} bytes failed ({:?})", bytes, e);
                null_mut() /* yeesh */
            }
        }
    }

    unsafe fn dealloc(&self, ptr: *mut u8, _layout: Layout)
    {
        klog!("heap: freeing {:p}", ptr);
        match (*<::cpu::Core>::this()).heap.free::<u8>(ptr)
        {
            Err(e) =>
            {
                kalert!("Kallocator: request to free {:p} failed ({:?})", ptr, e)
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
    size: usize,
    /* define block state using magic words */
    magic: HeapMagic
    /* block contents follows... */
}

/* this is our own internal API for the per-CPU kernel heap. use high-level abstractions, such as Box,
rather than this directly, so we get all the safety measures and lifetime checking. think of kallocator
as the API and Heap as the engine. kallocator is built on top of Heap, and each CPU core has its own Heap. */
#[repr(C)]
pub struct Heap
{
    /* pointer to list of in-use and freed blocks */
    block_list_head: *mut HeapBlock,
    /* stash a copy of the block header size here */
    block_header_size: usize
}

impl Heap
{
    /* initialize this heap area. start off with one giant block
    covering all of free space, from which other blocks will be carved.
    => start = pointer to start of heap area
       size = size of available bytes in heap */
    pub fn init(&mut self, start: *mut HeapBlock, size: usize)
    {
        /* here's our enormo free block */
        unsafe
        {
            let block = start;
            (*block).size = size;
            (*block).next = None;
            (*block).magic = HeapMagic::Free;

            self.block_header_size = mem::size_of::<HeapBlock>();
            self.block_list_head = block;
        }
    }

    /* free a previously allocated block
    => to_free = pointer previously returned by alloc()
    <= success or failure code */
    pub fn free<T>(&mut self, to_free: *mut T) -> Result<(), Cause>
    {
        /* convert this into a raw pointer so we can find the heap block header */
        let mut ptr = to_free as usize;
        ptr = ptr - self.block_header_size;
        let block = ptr as *mut HeapBlock;
        
        unsafe
        {
            match (*block).magic
            {
                /* assume writes are atomic... */
                HeapMagic::InUse =>
                {
                    (*block).magic = HeapMagic::Free;
                    Ok(())
                },
                /* if it's not in use, or bad magic, then bail out */
                HeapMagic::Free => Err(Cause::HeapNotInUse)
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

        /* calculate size of block required, including header, rounded up to
        nearest whole heap block multiple */
        let mut size_req = (mem::size_of::<T>() * num) + mem::size_of::<HeapBlock>();
        size_req = ((size_req / HEAP_BLOCK_SIZE) + 1) * HEAP_BLOCK_SIZE;

        /* scan all blocks for first free fit */
        let mut search_block = self.block_list_head;
        unsafe
        {
            while !done
            {
                if (*search_block).magic == HeapMagic::Free && (*search_block).size >= size_req
                {
                    /* we've got a winner. if the found block is equal size, or only a few bytes
                    larger than the required size, then take the whole block */
                    if ((*search_block).size - size_req) < HEAP_BLOCK_SIZE
                    {
                        (*search_block).magic = HeapMagic::InUse;
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
                        (*alloc_block).magic = HeapMagic::InUse;
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
                        /* if we can't squeeze any more bytes out then give up */
                        done = true;
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

    /* pass once over the heap and try to merge adjacent blocks
    <= size of the lagrest block seen, in bytes including header */
    fn consolidate(&mut self) -> usize
    {
        let mut largest_merged_block: usize = 0;

        let mut block = self.block_list_head;
        unsafe
        {
            /* can't merge if we're the last block in the list */
            while (*block).next.is_some()
            {
                let next = (*block).next.unwrap();
                if (*block).magic == HeapMagic::Free && (*next).magic == HeapMagic::Free
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
            if (*self.block_list_head).magic == HeapMagic::Free
            {
                match (*self.block_list_head).next
                {
                    Some(next) =>
                    {
                        if (*next).magic == HeapMagic::Free
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
}

