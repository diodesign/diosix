/* diosix machine kernel's per-CPU heap management
 *
 * (c) Chris Williams, 2018.
 *
 * See LICENSE for usage and copying.
 */

/* kalloc/kfree macros will get noisy otherwise */
#![allow(unused_unsafe)]

use core::mem;
use core::result::Result;
use error::Cause;

/* CPUs get their own private heaps to manage. Crucially, these memory
blocks can be used by other CPUs. Any CPU can free any block by marking
it as free in its metadata. When allocating, a CPU can only draw from
its own heap, reusing any blocks freed by itself or other cores.
If it can't find any suitable free blocks, then it must allocate from
its own heap's free area. The machine/hypervisor layer is unlikely
to do much active allocation so it's OK to keep it really simple for now.

This should avoid any locks and data races, and any contention. */

/* get some help from underlying platform */
extern "C"
{
    fn platform_cpu_heap_base() -> *mut HeapBlock;
    fn platform_cpu_heap_size() -> usize;
}

/* define some handy macros */
/* wrap a nice interface around the default per-CPU kernel heap */
macro_rules! kalloc
{
    ($type:ty) => (unsafe { (*<::cpu::Core>::this()).heap.alloc::<$type>()? } )
}
macro_rules! kfree
{
    ($type:ty, $addr:ident) => (unsafe { (*<::cpu::Core>::this()).heap.free::<$type>($addr)? } )
}

#[derive(PartialEq, Debug)]
#[repr(C)]
enum HeapMagic
{
    Free = 0x0deadded,
    InUse = 0x0d10c0de
}

/* to avoid fragmentation, allocate in block sizes of this multiple, including header */
const HEAP_BLOCK_SIZE: usize = 64;

#[repr(C)]
struct HeapBlock
{
    /* heap is a single-link-list to keep it simple and safe */
    next: Option<*mut HeapBlock>,
    /* size of this block *including* header */
    size: usize,
    /* define block state using magic words */
    magic: HeapMagic
    /* block contents follows... */
}

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
    covering all of free space, from which other blocks will be carved */
    pub fn init(&mut self)
    {
        /* here's our enormo free block */
        unsafe
        {
            let block = platform_cpu_heap_base();
            (*block).size = platform_cpu_heap_size();
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
                HeapMagic::Free => Err(Cause::HeapNotInUse),
                              _ => Err(Cause::HeapBadBlock)
            }
        }
    }

    /* allocate memory for the given object type. the returned pointer skips
    the heap block header, just like malloc() on other platforms.
    => T = type to allocate memory for
    <= pointer to memory, or error code */
    pub fn alloc<T>(&mut self) -> Result<*mut T, Cause>
    {
        let mut done = false;

        /* calculate size of block required, including header, rounded up to
        nearest whole heap block multiple */
        let mut size_req = mem::size_of::<T>() + mem::size_of::<HeapBlock>();
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

    /* output debug stats for this heap */
    pub fn debug(&mut self)
    {
        let mut blocks = 0;
        let mut inuse = 0;
        let mut free = 0;

        let mut block = self.block_list_head;
        {
            unsafe
            {
                loop
                {
                    blocks = blocks + 1;
                    match (*block).magic
                    {
                        HeapMagic::Free => free = free + (*block).size,
                        HeapMagic::InUse => inuse = inuse + (*block).size
                    };
                    match (*block).next
                    {
                        Some(n) => block = n,
                        None => break,
                    };
                }
            }
        }

        klog!("heap: {} blocks present. {} bytes in use, {} bytes free", blocks, inuse, free);
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