/* Reference OpenSBI M-mode Handoff Extension + U-Boot `mexec` Command.
 *
 * Allows stock S-mode U-Boot Proper (with working Ethernet/USB-NIC drivers)
 * to load `vmdiosix.bin` + `board.dtb` over TFTP and jump directly to the
 * hypervisor entry point in Machine mode (M-mode): a0 = hartid, a1 = dtb_pa.
 *
 * Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
 * SPDX-License-Identifier: MIT
 */

#include <stdint.h>

#define SBI_EXT_DIOSIX_MEXEC  0x09000d10UL
#define SBI_FID_JUMP_MMODE    0x0UL

/* ---------- Part A: OpenSBI Platform Vendor Handler (M-mode) ---------- */
#ifdef OPENSBI_PLATFORM_VENDOR_HANDLER

/* Minimal CSR helpers inside OpenSBI M-mode firmware. */
static inline void write_csr_satp(unsigned long v)
{
    __asm__ volatile("csrw satp, %0" :: "r"(v) : "memory");
}

static inline void write_csr_mie(unsigned long v)
{
    __asm__ volatile("csrw mie, %0" :: "r"(v) : "memory");
}

static inline void clear_mstatus_mie(void)
{
    __asm__ volatile("csrc mstatus, %0" :: "r"(1UL << 3) : "memory");
}

/* Vendor extension entry called by OpenSBI sbi_ecall_vendor_handler().
 * arg0 = physical entry address of vmdiosix.bin (e.g. 0x80000000)
 * arg1 = physical address of FDT blob (e.g. 0x88000000)
 */
int sbi_diosix_mexec_handler(unsigned long entry_pa, unsigned long dtb_pa,
                             unsigned long hartid)
{
    typedef void (*mmode_entry_fn)(unsigned long a0, unsigned long a1);

    if (entry_pa == 0 || dtb_pa == 0)
        return -3; /* SBI_ERR_INVALID_PARAM */

    clear_mstatus_mie();
    write_csr_mie(0);
    write_csr_satp(0);
    __asm__ volatile("fence iorw, iorw; fence.i" ::: "memory");

    /* Wake secondary harts via HSM or release wait loop at same entry_pa. */
    ((mmode_entry_fn)entry_pa)(hartid, dtb_pa);
    return 0;
}

#endif /* OPENSBI_PLATFORM_VENDOR_HANDLER */

/* ---------- Part B: U-Boot `mexec <entry_pa> <dtb_pa>` (S-mode) -------- */
#ifdef UBOOT_MEXEC_COMMAND

static inline long sbi_call_mexec(unsigned long entry_pa, unsigned long dtb_pa)
{
    register unsigned long a0 __asm__("a0") = entry_pa;
    register unsigned long a1 __asm__("a1") = dtb_pa;
    register unsigned long a6 __asm__("a6") = SBI_FID_JUMP_MMODE;
    register unsigned long a7 __asm__("a7") = SBI_EXT_DIOSIX_MEXEC;
    __asm__ volatile("ecall"
                     : "+r"(a0), "+r"(a1)
                     : "r"(a6), "r"(a7)
                     : "memory");
    return (long)a0;
}

int diosix_uboot_do_mexec(unsigned long entry_pa, unsigned long dtb_pa)
{
    return (int)sbi_call_mexec(entry_pa, dtb_pa);
}

#endif /* UBOOT_MEXEC_COMMAND */
