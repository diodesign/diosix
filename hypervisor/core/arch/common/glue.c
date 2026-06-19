/*
 * Architecture-independent Unicorn Engine glue for Diosix hypervisor.
 *
 * Contains helpers that work for all guest architectures and do not
 * need target-specific QEMU headers.
 *
 * Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
 * SPDX-License-Identifier: MIT
 */

#include "uc_priv.h"

/*
 * Clear stale stop/exit flags after an asynchronous uc_emu_stop.
 *
 * uc_emu_stop sets uc->stop_request and calls cpu_exit() which sets
 * cpu->exit_request and cpu->tcg_exit_req. uc_emu_start resets
 * stop_request but does NOT reset the CPU-level exit flags. This
 * causes the JIT to immediately exit on the next uc_emu_start call.
 *
 * Call this after uc_emu_start returns and before calling it again
 * to ensure the JIT loop can run to completion (or until the next
 * preemption).
 */
void diosix_uc_clear_stop(void *uc)
{
    struct uc_struct *u = (struct uc_struct *)uc;
    if (u) {
        u->stop_request = false;
        if (u->cpu) {
            u->cpu->exit_request = 0;
            u->cpu->tcg_exit_req = 0;
            u->cpu->icount_decr_ptr->u16.high = 0;
        }
    }
}
