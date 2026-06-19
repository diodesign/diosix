/*
 * RISC-V 32-bit guest Unicorn Engine glue for Diosix hypervisor.
 *
 * Provides thin wrappers around Unicorn/QEMU internal APIs for
 * emulating riscv32 guests. Compiled with access to Unicorn's
 * RISC-V internal headers (riscv32-softmmu target).
 *
 * Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
 * SPDX-License-Identifier: MIT
 */

#include "uc_priv.h"
#include "cpu.h"

/* Forward declaration for QEMU's native RISC-V exception handler. */
void riscv_cpu_do_interrupt(CPUState *cs);

/*
 * RISC-V mcause interrupt bit: bit 31 for RV32, bit 63 for RV64.
 * When set in exception_index, indicates an asynchronous interrupt
 * rather than a synchronous exception.
 */
#define RISCV_RV32_INTERRUPT_BIT  (1u << 31)

/*
 * Debug info struct populated by diosix_uc_rv32_do_interrupt for
 * Zig-side tracing.
 */
struct diosix_interrupt_info {
    uint32_t pre_priv;
    uint32_t pre_pc;
    uint32_t pre_stvec;
    uint32_t pre_mtvec;
    uint32_t pre_medeleg;
    uint32_t pre_badaddr;
    uint32_t pre_mstatus;
    uint32_t post_pc;
    uint32_t post_sepc;
    uint32_t post_scause;
    uint32_t post_stval;
    uint32_t post_priv;
};

/*
 * Register an rdtime callback with Unicorn's RISC-V CPU state.
 */
void diosix_uc_set_rdtime_fn(void *uc, uint64_t (*fn)(void))
{
    struct uc_struct *u = (struct uc_struct *)uc;
    if (u && u->cpu && u->cpu->env_ptr) {
        riscv_cpu_set_rdtime_fn((CPURISCVState *)u->cpu->env_ptr, fn);
    }
}

/*
 * Deliver an exception to a 32-bit RISC-V guest using QEMU's native
 * riscv_cpu_do_interrupt.
 *
 * Populates the provided info struct with pre/post interrupt state
 * for debug tracing by the Zig caller.
 */
void diosix_uc_do_interrupt(void *uc, int exception_index,
                            struct diosix_interrupt_info *info)
{
    struct uc_struct *u = (struct uc_struct *)uc;
    if (u && u->cpu) {
        CPURISCVState *env = (CPURISCVState *)u->cpu->env_ptr;

        /* Undo the +4 that cpu-exec.c adds before the INTR hook. */
        env->pc -= 4;

        /* Capture pre-interrupt state */
        if (info) {
            info->pre_priv = (uint32_t)env->priv;
            info->pre_pc = (uint32_t)env->pc;
            info->pre_stvec = (uint32_t)env->stvec;
            info->pre_mtvec = (uint32_t)env->mtvec;
            info->pre_medeleg = (uint32_t)env->medeleg;
            info->pre_badaddr = (uint32_t)env->badaddr;
            info->pre_mstatus = (uint32_t)env->mstatus;
        }

        /* Set the exception index and call QEMU's native handler. */
        u->cpu->exception_index = exception_index;
        riscv_cpu_do_interrupt(u->cpu);

        /* Capture post-interrupt state */
        if (info) {
            info->post_pc = (uint32_t)env->pc;
            info->post_sepc = (uint32_t)env->sepc;
            info->post_scause = (uint32_t)env->scause;
            info->post_stval = (uint32_t)env->sbadaddr;
            info->post_priv = (uint32_t)env->priv;
        }
    }
}

/*
 * Inject an asynchronous interrupt (e.g., timer) into a 32-bit RISC-V
 * guest from the run loop.
 *
 * Unlike diosix_uc_do_interrupt (which is called from the INTR hook
 * and must undo the cpu-exec.c PC += 4), this function is called
 * between uc_emu_start calls where env->pc is already correct.
 *
 * The cause is ORed with the interrupt bit (bit 31 for RV32) to tell
 * riscv_cpu_do_interrupt this is an async interrupt, not a sync exception.
 *
 * @uc:    Opaque pointer to a uc_engine instance.
 * @cause: Interrupt cause number (e.g. 5 for supervisor timer).
 */
void diosix_uc_inject_interrupt(void *uc, int cause)
{
    struct uc_struct *u = (struct uc_struct *)uc;
    if (u && u->cpu) {
        /* Set interrupt bit to indicate async interrupt */
        u->cpu->exception_index = cause | RISCV_RV32_INTERRUPT_BIT;
        riscv_cpu_do_interrupt(u->cpu);
    }
}
