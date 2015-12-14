/*
 * diosix microkernel 'menchi'
 *
 * Manage page table structures in x86 systems
 *
 * Maintainer: Chris Williams (diosix.org)
 *
 */

use rlibc::memset;

use errors::KernelInternalError;
use core::mem::size_of;
use spin::Mutex;
use core::ptr;

use ::hardware::pgstack;
use ::hardware::physmem;

extern
{
    static boot_pml4_ptr: usize;
}

const PG_PRESENT:        usize = 1 << 0; /* set to make this page entry valid */
pub const PG_WRITEABLE:  usize = 1 << 1; /* set this bit to make page writeable */
pub const PG_USER_ALLOW: usize = 1 << 2; /* set this bit to allow access from userspace */
const PG_2M_PAGE:        usize = 1 << 7; /* set to indicate a 2M page */
pub const PG_GLOBAL:     usize = 1 << 8; /* set to indicate this is a global page */
pub const PG_NOEXECUTE:  usize = 1 << 63; /* set to forbid execution in this page */

const PG_2M_FLAGS:       usize = (1 << 13) - 1; /* flags that can be set in a 2MB entry (bits 0-12) */

const PML4_INDEX_SHIFT:  usize = 39; /* index into PML4 table is in bits 39-47 of the virtual address */
const PDP_INDEX_SHIFT:   usize = 30; /* index into PDP table is in bits 30-38 of the virtual address */
const PD_INDEX_SHIFT:    usize = 21; /* index into PD table is in bits 21-29 of the virtual address */
const PG_TBL_INDEX_MASK: usize = 0b111111111; /* indexes are 9-bits wide (0-511) */

/* in a page table entry that points to another table, the lowest 12 bits and the uppermost bit
 * (the nx bit) are flags. this is mask just leaves the address from the entry. */
const TABLE_ADDR_MASK: usize = !(0b111111111111 | PG_NOEXECUTE);

pub static BOOTPGTABL: Mutex<PageTable> = Mutex::new(PageTable{pml4: 0});

pub struct PageTable
{
    pml4: usize, /* physical address of the pml4 */
}

impl PageTable
{
    /* need this function because we can't set pml4 in PageTable using boot_pml4_ptr during
     * initialization of BOOTPGTABL (rust error code E0394). so this func will do it for us. */
    pub fn use_boot_pml4(&mut self)
    {
        self.pml4 = boot_pml4_ptr;
    }

    fn table_entry_addr(&self, base: usize, index: usize) -> usize
    {
        base + (index * size_of::<usize>())
    }

    /* get_pdp
     *
     * Find the base address of the PDP (level 3) table responsible for the given virtual address.
     * if no PDP table is found, one is allocated, cleaned and its base pointer returned.
     * => virt = virtual address to examine
     * <= base address of the pdp table, or an error code on failure.
     */
    fn get_pdp(&self, virt: usize) -> Result<usize, KernelInternalError>
    {
        /* find the PML4 table entry that points to the PDP table we need.
         * a PML4 table is an array of 512 64-bit words. */
        let pml4 = unsafe{ &*((self.pml4) as *mut [usize; 512]) };
        let pml4_index = (virt >> PML4_INDEX_SHIFT) & PG_TBL_INDEX_MASK;

        /* when a PDP table is deallocated, the entry in the PML4 pointing to it must
         * be zero. this indicates no table is longer allocated. */
        if pml4[pml4_index] == 0
        {
            /* no table allocated, so we need to grab a physical page to hold
             * a new PDP table for the PML4 to point to */
            let pdp: usize = try!(pgstack::SYSTEMSTACK.lock().pop());

            /* zero the new PDP table so its entries are all marked not present */
            unsafe{ memset(pdp as *mut u8, 0, physmem::SMALL_PAGE_SIZE) };
            
            /* mark the PDP table as r/w and user-accessible to keep all options open.
             * these flags can be controlled at the lowest level of the paging structure. */
            let pml4_entry: usize = pdp | PG_PRESENT | PG_WRITEABLE | PG_USER_ALLOW;

            /* write new PDP entry in the PML4 table */
            unsafe{ ptr::write(self.table_entry_addr(self.pml4, pml4_index) as *mut _, pml4_entry) };
        }

        /* extract the PDP table address from the PML4 */
        Ok(pml4[pml4_index] & TABLE_ADDR_MASK)
    }

    /* get_pd
     *
     * Find the base address of the PD (level 2) table responsible for the given virtual address.
     * if no PD table is found, one is allocated, cleaned and its base pointer returned.
     * => virt = virtual address to examine
     * <= base address of the pdp table, or an error code on failure.
     */
    fn get_pd(&self, virt: usize) -> Result<usize, KernelInternalError>
    {
        /* find the PDP table entry that points to the PD table we need.
         * a PDP table is an array of 512 64-bit words. */
        let pdp_base = try!(self.get_pdp(virt));
        let pdp = unsafe{ &*((pdp_base) as *mut [usize; 512]) };
        let pdp_index = (virt >> PDP_INDEX_SHIFT) & PG_TBL_INDEX_MASK;

        /* when a PD table is deallocated, the entry in the PDP pointing to it must
         * be zero. this indicates no table is longer allocated. */
        if pdp[pdp_index] == 0
        {
            /* no table allocated, so we need to grab a physical page to hold
             * a new PDP table for the PML4 to point to */
            let pd: usize = try!(pgstack::SYSTEMSTACK.lock().pop());

            /* zero the new PDP table so its entries are all marked not present */
            unsafe{ memset(pd as *mut u8, 0, physmem::SMALL_PAGE_SIZE) };
            
            /* mark the PDP table as r/w and user-accessible to keep all options open.
             * these flags can be controlled at the lowest level of the paging structure. */
            let pdp_entry: usize = pd | PG_PRESENT | PG_WRITEABLE | PG_USER_ALLOW;

            /* write new PD entry in the PDP table */
            unsafe{ ptr::write(self.table_entry_addr(pdp_base, pdp_index) as *mut _, pdp_entry) };
        }

        /* extract the PDP table address from the PML4 */
        Ok(pdp[pdp_index] & TABLE_ADDR_MASK)
    }
    
    /* nx_bit
     *
     * Return the NX bit (bit 63) set if flags has the witeable bit set.
     * => flags = page table entry flags
     * <= 0 or NX bit set
     */
    fn nx_bit(&self, flags: usize) -> usize
    {
        if flags & PG_WRITEABLE == PG_WRITEABLE
        {
            return PG_NOEXECUTE;
        }

        0
    }

    /* map_2m_page
     *
     * Map a 2MB virtual page to physical RAM. Will allocate tables on the fly to fulfill the
     * request. Will update an existing 2MB mapping if one already exists. Will not overwrite
     * a 4KB mapping.
     * => virt = virtual base address of page to map to physical memory.
     *    phys = physical base address to use.
     *    flags = page settings: PG_WRITEABLE = make writeable, PG_USER = allow userspace to access
     * <= return error code on failure
     */
    pub fn map_2m_page(&mut self, virt: usize, phys: usize, flags: usize) -> Result<(), KernelInternalError>
    {
        /* if the page is writeable, it cannot be executable. Mutable code is bad news,
         * security-wise. ensure the no-execute (NX) bit is set in the lowest page table
         * entry if the page is writeable. */
        let nx = self.nx_bit(flags);

        /* ensure the virtual and physical addresses are sane: they must be aligned 
         * to a 2MB boundary. */
        if virt % physmem::LARGE_PAGE_SIZE != 0 { return Err(KernelInternalError::BadVirtPgAddress); }
        if phys % physmem::LARGE_PAGE_SIZE != 0 { return Err(KernelInternalError::BadPhysPgAddress); }

        /* get the page directory (level 1) for this 2M page */
        let pd_base: usize = try!(self.get_pd(virt));
        let pd = unsafe{ &*((pd_base) as *mut [usize; 512]) };

        let pd_index: usize = (virt >> PD_INDEX_SHIFT) & PG_TBL_INDEX_MASK;

        /* check to make sure the PD entry for this virtual address
         * is not in use by a 4K table */
        if pd[pd_index] & PG_2M_PAGE == 0 && pd[pd_index] != 0
        {
            return Err(KernelInternalError::Pg4KTablePresent);
        }

        /* update 2MB page entry in the page dirctory */
        let pd_entry: usize = phys | PG_2M_PAGE | PG_PRESENT | nx | (flags & PG_2M_FLAGS);
        unsafe{ ptr::write(self.table_entry_addr(pd_base, pd_index) as *mut _, pd_entry) };

        Ok(())
    }

    /* load
     *
     * Load the page tables into the CPU. Note: any pages marked global are not affected
     * by this push.
     */
    pub fn load(&self)
    {
        unsafe
        {
            asm!("mov %cr3, %rax" : : "{rax}"(self.pml4));
        }
    }
}


