/* SPDX-License-Identifier: MIT */
/*
 * Diosix Hypervisor Guest Character Driver (/dev/diosix) shared definitions.
 *
 * Exposes hypercall constants, ioctl command IDs, and ABI structures shared
 * across the /dev/diosix character device, governance helpers, and virtual
 * network interface.
 *
 * Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
 */

#ifndef DIOSIX_DRIVER_H
#define DIOSIX_DRIVER_H

#ifdef __KERNEL__
#include <linux/types.h>
#include <linux/errno.h>
#include <linux/fs.h>
#else
#include <errno.h>
#include <stdint.h>
#endif

#define EXT_DIOSIX 0x0a000005

#define DIOSIX_FUNC_TERMINATE             0
#define DIOSIX_FUNC_EXIT                  0
#define DIOSIX_FUNC_YIELD                 1
#define DIOSIX_FUNC_DROP_TRUST            3
#define DIOSIX_FUNC_RUN                   4
#define DIOSIX_FUNC_SPAWN                 4
#define DIOSIX_FUNC_GET_INFO              5
#define DIOSIX_FUNC_SET_QUOTA             6
#define DIOSIX_FUNC_POLL_EVENT            9
#define DIOSIX_FUNC_GET_HV_INFO           10
#define DIOSIX_FUNC_GET_MANIFEST          11
#define DIOSIX_FUNC_SET_MANIFEST          12
#define DIOSIX_FUNC_MAP_CHILD_MEM         13
#define DIOSIX_FUNC_UNMAP_CHILD_MEM       14
#define DIOSIX_FUNC_START                 15
#define DIOSIX_FUNC_NET_SEND              16
#define DIOSIX_FUNC_NET_RECV              17
#define DIOSIX_FUNC_NET_POLL              18
#define DIOSIX_FUNC_SEAL_CHARTER          19
#define DIOSIX_FUNC_RATIFY_CHARTER        20
#define DIOSIX_FUNC_WHISPER_SEND          21
#define DIOSIX_FUNC_WHISPER_RECV          22
#define DIOSIX_FUNC_RESET_STEWARD         23
#define DIOSIX_FUNC_REQUEST_ROOT_FAILOVER 24

#define IOCTL_DROP_TRUST            0x1002
#define IOCTL_RUN                   0x1003
#define IOCTL_SPAWN                 0x1003
#define IOCTL_GET_INFO              0x1004
#define IOCTL_SET_QUOTA             0x1005
#define IOCTL_TERMINATE             0x1006
#define IOCTL_EXIT                  0x1006
#define IOCTL_KILL                  0x1006
#define IOCTL_YIELD                 0x1007
#define IOCTL_WAIT_EVENT            0x1008
#define IOCTL_GET_HV_INFO           0x100b
#define IOCTL_GET_MANIFEST          0x100c
#define IOCTL_SET_MANIFEST          0x100d
#define IOCTL_MAP_CHILD_MEM         0x100e
#define IOCTL_UNMAP_CHILD_MEM       0x100f
#define IOCTL_START                 0x1010
#define IOCTL_SEAL_CHARTER          0x1011
#define IOCTL_GET_CHARTER           0x1012
#define IOCTL_RATIFY_CHARTER        0x1013
#define IOCTL_RESET_STEWARD         0x1014
#define IOCTL_REQUEST_ROOT_FAILOVER 0x1015

#define DIOSIX_CHILD_MEM_BASE       0x200000000UL
#define DIOSIX_CHILD_MEM_MAX_SIZE   (256UL * 1024 * 1024)
#define DIOSIX_MAX_ELF_SIZE         (512UL * 1024 * 1024)
#define DIOSIX_MAX_EXACT_ALLOC_SIZE (2UL * 1024 * 1024)
#define DIOSIX_MAX_DTB_SIZE         DIOSIX_MAX_EXACT_ALLOC_SIZE
#define DIOSIX_MAX_MANIFEST_SIZE    (1024UL * 1024)
#define DIOSIX_NET_MAX_FRAME_SIZE   1536UL

#define DIOSIX_CID_PARENT           0UL
#define DIOSIX_CID_SELF             1UL
#define DIOSIX_WAIT_FLAG_NONBLOCK   0x1UL
#define DIOSIX_EVENT_POLL_MS        50
#define DIOSIX_CHARTER_OP_QUERY     0UL
#define DIOSIX_CHARTER_OP_SEAL      1UL
#define DIOSIX_MAC_PREFIX_BYTE0     0x02

#define DIOSIX_SBI_ERR_FAILED            (-1L)
#define DIOSIX_SBI_ERR_NOT_SUPPORTED     (-2L)
#define DIOSIX_SBI_ERR_INVALID_PARAM     (-3L)
#define DIOSIX_SBI_ERR_DENIED            (-4L)
#define DIOSIX_SBI_ERR_INVALID_ADDRESS   (-5L)
#define DIOSIX_SBI_ERR_ALREADY_AVAILABLE (-6L)

static inline long diosix_sbi_to_errno(long sbi_err)
{
    switch (sbi_err) {
    case 0:
        return 0;
    case DIOSIX_SBI_ERR_NOT_SUPPORTED:
        return -EOPNOTSUPP;
    case DIOSIX_SBI_ERR_INVALID_PARAM:
        return -EINVAL;
    case DIOSIX_SBI_ERR_DENIED:
        return -EPERM;
    case DIOSIX_SBI_ERR_INVALID_ADDRESS:
        return -EFAULT;
    case DIOSIX_SBI_ERR_ALREADY_AVAILABLE:
        return -EEXIST;
    case DIOSIX_SBI_ERR_FAILED:
    default:
        return -EIO;
    }
}

struct charter_args {
    uint8_t  charter_hash[32];
    uint16_t quorum_required;
    uint16_t quorum_total;
    uint16_t standby_replicas;
    uint8_t  is_sealed;
    uint8_t  _reserved;
    uint64_t ratified_mask;
    uint64_t approved_target_cid;
    uint64_t failover_epoch;
};

struct map_child_mem_args {
    uint64_t child_id;
    uint64_t child_gpa;
    uint64_t parent_gpa;
    uint64_t size;
    uint64_t flags;
};

struct unmap_child_mem_args {
    uint64_t parent_gpa;
    uint64_t size;
};

struct start_args {
    uint64_t child_id;
    uint64_t entry_point;
    uint64_t dtb_ptr;
};

struct hypervisor_info {
    uint16_t abi_version_major;
    uint16_t abi_version_minor;
    uint16_t abi_version_patch;
    uint16_t version_major;
    uint16_t version_minor;
    uint16_t version_patch;
    uint32_t _reserved1;
    char     build_commit[16];
    uint64_t features;
    uint32_t host_physical_cores;
    uint32_t host_timer_freq_hz;
    uint64_t host_total_ram_kb;
    uint64_t host_free_ram_kb;
    uint64_t hv_reserved_bytes;
    uint64_t hv_heap_free_bytes;
    char     host_cpu_isa[32];
    char     build_desc[192];
};

struct diosix_event {
    uint64_t cid;
    uint32_t event_type;
    uint32_t exit_code;
    uint64_t _reserved;
};

struct wait_event_args {
    uint64_t target_cid;
    uint64_t flags;
    struct diosix_event event;
};

struct quota_args {
    uint64_t target_cid;
    uint64_t max_ram_pages;
    uint64_t max_vcpus;
    uint64_t max_child_depth;
    uint64_t max_descendants;
    uint64_t pcpu_quota_pct;
    uint64_t logical_ram_pages;
};

struct manifest_args {
    uint64_t target_cid;
    uint64_t data_ptr;
    uint64_t max_len;
    uint64_t actual_len;
};

struct run_args {
    uint64_t child_id;
    uint64_t elf_ptr;
    uint64_t elf_size;
    uint64_t dtb_ptr;
    uint64_t dtb_size;
    uint64_t target_arch;
    uint64_t flags;
};

struct terminate_args {
    uint64_t target_id;
    uint64_t exit_code;
};

struct guest_info {
    uint64_t guest_id;
    uint64_t parent_id;
    uint8_t  is_trusted;
    uint8_t  is_root;
    uint8_t  target_arch;
    uint8_t  assigned_cid;
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
};

_Static_assert(sizeof(struct charter_args) == 64, "charter_args ABI size");
_Static_assert(
    sizeof(struct map_child_mem_args) == 40,
    "map_child_mem_args ABI size"
);
_Static_assert(
    sizeof(struct unmap_child_mem_args) == 16,
    "unmap_child_mem_args ABI size"
);
_Static_assert(sizeof(struct start_args) == 24, "start_args ABI size");
_Static_assert(
    sizeof(struct hypervisor_info) == 304,
    "hypervisor_info ABI size"
);
_Static_assert(sizeof(struct diosix_event) == 24, "diosix_event ABI size");
_Static_assert(
    sizeof(struct wait_event_args) == 40,
    "wait_event_args ABI size"
);
_Static_assert(sizeof(struct quota_args) == 56, "quota_args ABI size");
_Static_assert(sizeof(struct manifest_args) == 32, "manifest_args ABI size");
_Static_assert(sizeof(struct run_args) == 56, "run_args ABI size");
_Static_assert(sizeof(struct terminate_args) == 16, "terminate_args ABI size");
_Static_assert(sizeof(struct guest_info) == 96, "guest_info ABI size");

void diosix_child_mem_lock(void);
void diosix_child_mem_unlock(void);
long diosix_ioctl_governance(unsigned int cmd, unsigned long arg);
int init_diosix_net(void);
void cleanup_diosix_net(void);

#endif /* DIOSIX_DRIVER_H */
