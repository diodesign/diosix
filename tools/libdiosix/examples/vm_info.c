/*
 * Minimal libdiosix example: query hypervisor and self guest telemetry.
 *
 * Cross-compile inside the SDK:
 *   zig cc -target riscv64-linux-musl -Iinclude examples/vm_info.c \
 *       lib/libdiosix.a -o vm_info
 *
 * Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
 * SPDX-License-Identifier: MIT
 */

#include <inttypes.h>
#include <stdio.h>

#include "diosix.h"

int main(void) {
    diosix_ctx_t *ctx = NULL;
    diosix_hv_info_t hv;
    diosix_guest_info_t self;
    int rc = diosix_open_status(DIOSIX_DEFAULT_DEVICE_PATH, &ctx);

    if (rc != DIOSIX_OK) {
        fprintf(stderr, "diosix_open_status: %s\n", diosix_strerror(rc));
        return 1;
    }

    rc = diosix_get_hv_info(ctx, &hv);
    if (rc != DIOSIX_OK) {
        fprintf(stderr, "diosix_get_hv_info: %s\n", diosix_strerror(rc));
        diosix_close(ctx);
        return 1;
    }

    rc = diosix_get_guest_info(ctx, DIOSIX_CID_SELF, &self);
    if (rc != DIOSIX_OK) {
        fprintf(stderr, "diosix_get_guest_info: %s\n", diosix_strerror(rc));
        diosix_close(ctx);
        return 1;
    }

    printf("Diosix %u.%u.%u (SBI ABI %u.%u.%u)\n", hv.version_major,
           hv.version_minor, hv.version_patch, hv.abi_version_major,
           hv.abi_version_minor, hv.abi_version_patch);
    printf("Host cores: %u | Free RAM: %" PRIu64 " / %" PRIu64 " KiB\n",
           hv.host_physical_cores, hv.host_free_ram_kb, hv.host_total_ram_kb);
    printf("Guest CID: %" PRIu64 " | vCPUs: %" PRIu64 " | pCPU quota: %u%%\n",
           self.guest_id, self.vcpus, self.pcpu_quota_pct);

    diosix_close(ctx);
    return 0;
}
