/*
 * AArch64 guest Unicorn Engine glue for Diosix hypervisor.
 *
 * Provides thin wrappers around Unicorn/QEMU internal APIs for
 * emulating aarch64 guests. Compiled with access to Unicorn's
 * ARM64 internal headers (aarch64-softmmu target).
 *
 * Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
 * SPDX-License-Identifier: MIT
 */

#include "uc_priv.h"
#include "cpu.h"
#include "unicorn/arm64.h"

/* Forward declarations for QEMU's native ARM64 handlers. */
void arm_cpu_do_interrupt_aarch64(CPUState *cs);

/*
 * Deliver an exception to an AArch64 guest using QEMU's native handler.
 *
 * Sets the exception_index on the CPU and calls arm_cpu_do_interrupt,
 * which handles the full EL1 exception entry sequence: saving PSTATE
 * to SPSR_EL1, saving PC to ELR_EL1, setting ESR_EL1, and jumping to
 * the appropriate VBAR_EL1 vector.
 *
 * IMPORTANT: cpu-exec.c adds +4 to env->pc before calling the INTR
 * hook. We must undo this so that ELR_EL1 points to the faulting
 * instruction, not the one after it.
 *
 * @uc:               Opaque pointer to a uc_engine instance.
 * @exception_index:  QEMU exception number (EXCP_PREFETCH_ABORT, etc.)
 */
void diosix_uc_do_interrupt_arm64(void *uc, int exception_index)
{
    struct uc_struct *u = (struct uc_struct *)uc;
    if (u && u->cpu) {
        uint64_t *arm_pc = (uint64_t *)((char *)u->cpu->env_ptr + 320);
        *arm_pc -= 4;
        u->cpu->exception_index = exception_index;
        arm_cpu_do_interrupt_aarch64(u->cpu);
    }
}

/*
 * Disable QEMU's internal ARM64 MMU by clearing SCTLR_EL1.M (bit 0).
 *
 * When the guest enables the MMU via "msr sctlr_el1", QEMU's softmmu
 * starts doing page table walks for every instruction fetch and data
 * access. If the page table walk fails (because QEMU can't access the
 * guest's page tables properly), this causes infinite prefetch aborts.
 *
 * Since we map both physical and virtual address ranges directly in
 * Unicorn's flat memory, we don't need QEMU's MMU. This function
 * clears the M bit so QEMU stops trying to do page table walks.
 */
void diosix_uc_disable_arm64_mmu(void *uc)
{
    /* SCTLR_EL1 = op0=3, op1=0, crn=1, crm=0, op2=0 */
    uc_arm64_cp_reg sctlr = {
        .crn = 1, .crm = 0,
        .op0 = 3, .op1 = 0, .op2 = 0,
        .val = 0
    };

    /* Read current value. */
    uc_reg_read(uc, UC_ARM64_REG_CP_REG, &sctlr);

    /* Clear M bit (bit 0) to disable MMU. */
    sctlr.val &= ~1ULL;

    /* Write back. */
    uc_reg_write(uc, UC_ARM64_REG_CP_REG, &sctlr);
}

/*
 * Write a value directly to cp15.sctlr_el[1] in the CPUARMState.
 *
 * The MSR instruction for SCTLR_EL1 writes to the banked field
 * (cp15.sctlr_ns for non-secure state) via bank_fieldoffsets.
 * However, regime_sctlr() — which the page table walker and hflags
 * rebuild use — reads from cp15.sctlr_el[1]. This function syncs
 * the two so the page table walker sees the correct MMU-enable state.
 */
static void write_sctlr_el1(void *uc, uint64_t value)
{
    struct uc_struct *u = (struct uc_struct *)uc;
    if (u && u->cpu) {
        CPUARMState *env = (CPUARMState *)u->cpu->env_ptr;
        env->cp15.sctlr_el[1] = value;
    }
}

/*
 * Synchronize ARM64 MMU state after the guest enables the MMU.
 *
 * When the kernel executes "msr sctlr_el1" to enable the MMU, QEMU's
 * JIT generates code that calls sctlr_write() and rebuild_hflags().
 * However, the TTBR0/TTBR1 registers use banked storage (cp15.ttbr0_ns)
 * while the page table walker reads from cp15.ttbr0_el[1]. We sync
 * the banked values to the el[] array via UC_ARM64_REG_TTBR0_EL1,
 * then call arm_rebuild_hflags() to ensure the MMU-enabled state is
 * reflected in QEMU's internal hflags cache.
 *
 * This avoids modifying the Unicorn/QEMU source tree.
 */
void diosix_uc_arm64_sync_mmu_state(void *uc)
{
    struct uc_struct *u = (struct uc_struct *)uc;
    if (!u || !u->cpu) return;

    /* Sync ALL banked MMU registers from the CP_REG (banked) path to the
     * direct register path (which writes to the _el[1] / _el[] fields
     * that the page table walker reads).
     *
     * The problem: ARM_CP_STATE_BOTH registers with bank_fieldoffsets
     * store MSR values in the banked field (e.g. cp15.sctlr_ns), but
     * regime_sctlr()/regime_ttbr() read from cp15.sctlr_el[1] / ttbr0_el[1].
     */

    /* TTBR0_EL1 */
    uc_arm64_cp_reg ttbr0 = { .crn=2, .crm=0, .op0=3, .op1=0, .op2=0, .val=0 };
    uc_reg_read(uc, UC_ARM64_REG_CP_REG, &ttbr0);
    uc_reg_write(uc, UC_ARM64_REG_TTBR0_EL1, &ttbr0.val);

    /* TTBR1_EL1 */
    uc_arm64_cp_reg ttbr1 = { .crn=2, .crm=0, .op0=3, .op1=0, .op2=1, .val=0 };
    uc_reg_read(uc, UC_ARM64_REG_CP_REG, &ttbr1);
    uc_reg_write(uc, UC_ARM64_REG_TTBR1_EL1, &ttbr1.val);

    /* SCTLR_EL1 */
    uc_arm64_cp_reg sctlr = { .crn=1, .crm=0, .op0=3, .op1=0, .op2=0, .val=0 };
    uc_reg_read(uc, UC_ARM64_REG_CP_REG, &sctlr);
    write_sctlr_el1(uc, sctlr.val);

    /* Rebuild hflags so QEMU's internal MMU-enabled/disabled cache
     * reflects the current SCTLR_EL1.M state. */
    arm_rebuild_hflags((CPUARMState *)u->cpu->env_ptr);
}
