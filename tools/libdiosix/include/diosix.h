/*
 * Diosix Userland Hypervisor Control Library (libdiosix)
 *
 * Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
 * SPDX-License-Identifier: MIT
 */

#ifndef DIOSIX_H
#define DIOSIX_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define DIOSIX_DEFAULT_DEVICE_PATH "/dev/diosix"

#define DIOSIX_CID_PARENT      0ULL
#define DIOSIX_CID_SELF        1ULL
#define DIOSIX_CID_FIRST_CHILD 2ULL
#define DIOSIX_NO_PARENT_CID   UINT64_MAX

#define DIOSIX_BUILD_COMMIT_LEN     16
#define DIOSIX_HOST_CPU_ISA_LEN     32
#define DIOSIX_BUILD_DESC_LEN       192
#define DIOSIX_MAX_CONSOLE_IO_BYTES 4096

#define DIOSIX_CHARTER_HASH_LEN     32
#define DIOSIX_MISSION_PUBKEY_LEN   32
#define DIOSIX_MISSION_SIG_LEN      64
#define DIOSIX_MISSION_SIGN_MSG_LEN 92

#define DIOSIX_QUOTA_ZERO_SENTINEL UINT64_MAX
#define DIOSIX_WAIT_FLAG_NONBLOCK  (1ULL << 0)

#define DIOSIX_ARCH_RISCV64 0
#define DIOSIX_ARCH_RISCV32 1
#define DIOSIX_ARCH_AARCH64 2
#define DIOSIX_ARCH_X86_64  3

#define DIOSIX_FEAT_HARDWARE_VIRT  (1ULL << 0)
#define DIOSIX_FEAT_STAGE2_PAGING  (1ULL << 1)
#define DIOSIX_FEAT_DYNAREC        (1ULL << 2)
#define DIOSIX_FEAT_VIRTIO_VSOCK   (1ULL << 3)
#define DIOSIX_FEAT_IOMMU          (1ULL << 4)
#define DIOSIX_FEAT_RELEASE_STABLE (1ULL << 5)
#define DIOSIX_FEAT_CHARTER_SEALED (1ULL << 6)

#define DIOSIX_RUN_FLAG_TRUSTED          (1ULL << 0)
#define DIOSIX_RUN_FLAG_STEWARD          (1ULL << 1)
#define DIOSIX_RUN_FLAG_STANDBY_ROOT     (1ULL << 2)
#define DIOSIX_RUN_FLAG_CONFIDENTIAL     (1ULL << 3)
#define DIOSIX_RUN_FLAG_NET_ISOLATED     (1ULL << 4)
#define DIOSIX_RUN_FLAG_DELEGATE_STAKE   (1ULL << 5)
#define DIOSIX_RUN_FLAG_LEAF_NO_CHILDREN (1ULL << 6)
#define DIOSIX_RUN_NET_UPSTREAM_SHIFT    16
#define DIOSIX_RUN_NET_UPSTREAM_MASK     0xffffULL

#define DIOSIX_NET_POLICY_ISOLATED (1ULL << 0)

#define DIOSIX_EVENT_NONE                  0U
#define DIOSIX_EVENT_CHILD_TERMINATED      1U
#define DIOSIX_EVENT_CHILD_STOPPED         2U
#define DIOSIX_EVENT_CHILD_STARTED         3U
#define DIOSIX_EVENT_CHILD_MEMORY_PRESSURE 4U

#define DIOSIX_MISSION_FLAG_PROTECT_REPLICAS          (1U << 0)
#define DIOSIX_MISSION_FLAG_FORBID_UNRATIFIED_ENCRYPT (1U << 1)
#define DIOSIX_MISSION_FLAG_DESTRUCTIVE_ENCRYPT       (1U << 2)
#define DIOSIX_MISSION_FLAG_DESTRUCTIVE_WIPE          (1U << 3)

#define DIOSIX_VOTE_NONE    0
#define DIOSIX_VOTE_APPROVE 1
#define DIOSIX_VOTE_REJECT  2

typedef enum diosix_error {
    DIOSIX_OK                = 0,
    DIOSIX_ERR_NO_DEVICE     = -1,
    DIOSIX_ERR_DENIED        = -2,
    DIOSIX_ERR_NOT_SUPPORTED = -3,
    DIOSIX_ERR_WOULD_BLOCK   = -4,
    DIOSIX_ERR_INVALID_ARG   = -5,
    DIOSIX_ERR_NO_MEMORY     = -6,
    DIOSIX_ERR_HYPERCALL     = -7
} diosix_error_t;

typedef struct diosix_hv_info {
    uint16_t abi_version_major;
    uint16_t abi_version_minor;
    uint16_t abi_version_patch;
    uint16_t version_major;
    uint16_t version_minor;
    uint16_t version_patch;
    uint32_t _reserved1;
    uint8_t build_commit[DIOSIX_BUILD_COMMIT_LEN];
    uint64_t features;
    uint32_t host_physical_cores;
    uint32_t host_timer_freq_hz;
    uint64_t host_total_ram_kb;
    uint64_t host_free_ram_kb;
    uint64_t hv_reserved_bytes;
    uint64_t hv_heap_free_bytes;
    char host_cpu_isa[DIOSIX_HOST_CPU_ISA_LEN];
    char build_desc[DIOSIX_BUILD_DESC_LEN];
} diosix_hv_info_t;

typedef struct diosix_guest_info {
    uint64_t guest_id;
    uint64_t parent_id;
    uint8_t is_trusted;
    uint8_t has_parent;
    uint8_t target_arch;
    uint8_t assigned_cid;
    uint32_t cpu_khz_ticks;
    uint64_t vcpus;
    uint64_t self_ram_pages;
    uint64_t used_vcpus;
    uint64_t max_vcpus;
    uint64_t used_ram_pages;
    uint64_t max_ram_pages;
    uint64_t child_count;
    uint32_t pcpu_quota_pct;
    uint32_t delegated_pcpu_pct;
    uint64_t delegated_ram_pages;
} diosix_guest_info_t;

typedef struct diosix_event {
    uint64_t cid;
    uint32_t event_type;
    uint32_t exit_code;
    uint64_t _reserved;
} diosix_event_t;

typedef struct diosix_run_args {
    uint64_t child_id;
    uint64_t elf_ptr;
    uint64_t elf_size;
    uint64_t dtb_ptr;
    uint64_t dtb_size;
    uint64_t target_arch;
    uint64_t flags;
} diosix_run_args_t;

typedef struct diosix_quota_args {
    uint64_t target_cid;
    uint64_t max_ram_pages;
    uint64_t max_vcpus;
    uint64_t max_child_depth;
    uint64_t max_descendants;
    uint64_t pcpu_quota_pct;
    uint64_t logical_ram_pages;
} diosix_quota_args_t;

typedef struct diosix_charter_args {
    uint8_t charter_hash[DIOSIX_CHARTER_HASH_LEN];
    uint16_t quorum_required;
    uint16_t quorum_total;
    uint16_t standby_replicas;
    uint8_t is_sealed;
    uint8_t _reserved;
    uint64_t ratified_mask;
    uint64_t approved_target_cid;
    uint64_t failover_epoch;
} diosix_charter_args_t;

typedef struct diosix_mission_args {
    uint8_t charter_hash[DIOSIX_CHARTER_HASH_LEN];
    uint8_t principal_pubkey[DIOSIX_MISSION_PUBKEY_LEN];
    uint8_t signature[DIOSIX_MISSION_SIG_LEN];
    uint32_t version;
    uint32_t min_total_replicas;
    uint32_t flags;
    uint8_t stake_quorum_pct;
    uint8_t max_stepdown_pct;
    uint8_t is_sealed;
    uint8_t has_pubkey;
    uint64_t eligible_stake_pages;
    uint64_t approved_stake_pages;
    uint64_t rejected_stake_pages;
    uint32_t voter_count;
    uint32_t _reserved;
} diosix_mission_args_t;

typedef struct diosix_mission_vote_args {
    uint8_t proposal_hash[DIOSIX_CHARTER_HASH_LEN];
    uint8_t decision;
    uint8_t _reserved[7];
    uint64_t caller_stake_pages;
    uint64_t eligible_stake_pages;
    uint64_t approved_stake_pages;
    uint64_t rejected_stake_pages;
} diosix_mission_vote_args_t;

typedef struct diosix_ctx diosix_ctx_t;

const char *diosix_strerror(int err);
diosix_ctx_t *diosix_open(void);
diosix_ctx_t *diosix_open_path(const char *path);
int diosix_open_status(const char *path, diosix_ctx_t **out_ctx);
void diosix_close(diosix_ctx_t *ctx);
int diosix_fd(const diosix_ctx_t *ctx);

int diosix_get_hv_info(diosix_ctx_t *ctx, diosix_hv_info_t *out_info);
int diosix_get_guest_info(diosix_ctx_t *ctx, uint64_t target_cid,
                          diosix_guest_info_t *out_info);
int diosix_drop_trust(diosix_ctx_t *ctx);
int diosix_yield(diosix_ctx_t *ctx);
int diosix_wait_event(diosix_ctx_t *ctx, uint64_t target_cid,
                      uint64_t flags, diosix_event_t *out_event);

int diosix_run_guest(diosix_ctx_t *ctx, const diosix_run_args_t *args,
                     uint64_t *out_cid);
int diosix_start_guest(diosix_ctx_t *ctx, uint64_t target_cid,
                       uint64_t entry_point, uint64_t dtb_ptr,
                       uint64_t *out_val);
int diosix_terminate(diosix_ctx_t *ctx, uint64_t target_cid,
                     uint64_t exit_code);
int diosix_set_quota(diosix_ctx_t *ctx, const diosix_quota_args_t *args);

int diosix_get_manifest(diosix_ctx_t *ctx, uint64_t target_cid, void *buf,
                        size_t max_len, size_t *out_len);
int diosix_set_manifest(diosix_ctx_t *ctx, uint64_t target_cid,
                        const void *buf, size_t len);
int diosix_console_read(diosix_ctx_t *ctx, uint64_t target_cid, void *buf,
                        size_t max_len, size_t *out_len);
int diosix_console_write(diosix_ctx_t *ctx, uint64_t target_cid,
                         const void *buf, size_t len, size_t *out_len);
int diosix_set_net_policy(diosix_ctx_t *ctx, uint64_t target_cid,
                          uint64_t flags, uint64_t upstream_cid);

int diosix_map_child_mem(diosix_ctx_t *ctx, uint64_t target_cid,
                         uint64_t child_gpa, uint64_t parent_gpa,
                         size_t size, uint64_t flags, void **out_ptr);
int diosix_unmap_child_mem(diosix_ctx_t *ctx, void *ptr, size_t size,
                           uint64_t parent_gpa);

int diosix_seal_charter(diosix_ctx_t *ctx,
                        const diosix_charter_args_t *args);
int diosix_get_charter(diosix_ctx_t *ctx, diosix_charter_args_t *out_args);
int diosix_ratify_charter(diosix_ctx_t *ctx, uint64_t target_cid,
                          uint64_t *out_mask);
int diosix_reset_steward(diosix_ctx_t *ctx, uint64_t target_cid,
                         uint64_t *out_val);
int diosix_request_root_failover(diosix_ctx_t *ctx, uint64_t standby_cid,
                                 uint64_t *out_val);

int diosix_seal_mission(diosix_ctx_t *ctx,
                        const diosix_mission_args_t *in_args,
                        diosix_mission_args_t *out_args);
int diosix_get_mission(diosix_ctx_t *ctx,
                       const uint8_t *proposal_hash_or_null,
                       diosix_mission_args_t *out_args);
int diosix_vote_mission(diosix_ctx_t *ctx,
                        const uint8_t proposal_hash[32],
                        uint8_t decision,
                        diosix_mission_vote_args_t *out_args);
int diosix_whisper_send(diosix_ctx_t *ctx, uint64_t target_cid,
                        const void *buf, size_t len, size_t *out_len);
int diosix_whisper_recv(diosix_ctx_t *ctx, void *buf, size_t max_len,
                        size_t *out_len);

#ifdef __cplusplus
}
#endif

#endif /* DIOSIX_H */
