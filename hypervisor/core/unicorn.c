/*
 * Unicorn Engine glue for Diosix hypervisor.
 *
 * Provides thin wrappers around Unicorn/QEMU internal APIs that are not
 * exposed through Unicorn's public header. This file is compiled with
 * access to Unicorn's internal headers but lives in the Diosix codebase,
 * avoiding any modifications to the third-party Unicorn source tree.
 *
 * Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
 * SPDX-License-Identifier: MIT
 */

#include "uc_priv.h"
#include "cpu.h"

/*
 * Register an rdtime callback with Unicorn's RISC-V CPU state.
 *
 * When registered, guest rdtime/rdtimeh instructions execute entirely
 * inside the JIT loop by calling this function pointer, avoiding the
 * overhead of an exception stop and re-entry.
 *
 * @uc:  Opaque pointer to a uc_engine instance (from uc_open).
 * @fn:  Callback returning the current 64-bit time value.
 */
void diosix_uc_set_rdtime_fn(void *uc, uint64_t (*fn)(void))
{
    struct uc_struct *u = (struct uc_struct *)uc;
    if (u && u->cpu && u->cpu->env_ptr) {
        riscv_cpu_set_rdtime_fn((CPURISCVState *)u->cpu->env_ptr, fn);
    }
}
