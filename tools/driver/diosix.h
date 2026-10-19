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

#include <linux/types.h>
#include <linux/fs.h>

#define EXT_DIOSIX 0x0A000005

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
#define IOCTL_GET_HV_INFO           0x100B
#define IOCTL_GET_MANIFEST          0x100C
#define IOCTL_SET_MANIFEST          0x100D
#define IOCTL_MAP_CHILD_MEM         0x100E
#define IOCTL_UNMAP_CHILD_MEM       0x100F
#define IOCTL_START                 0x1010
#define IOCTL_SEAL_CHARTER          0x1011
#define IOCTL_GET_CHARTER           0x1012
#define IOCTL_RATIFY_CHARTER        0x1013
#define IOCTL_RESET_STEWARD         0x1014
#define IOCTL_REQUEST_ROOT_FAILOVER 0x1015

#define DIOSIX_CHILD_MEM_BASE     0x200000000UL
#define DIOSIX_CHILD_MEM_MAX_SIZE (256UL * 1024 * 1024)
#define DIOSIX_MAX_ELF_SIZE       (512UL * 1024 * 1024)
#define DIOSIX_MAX_DTB_SIZE       (16UL * 1024 * 1024)
#define DIOSIX_MAX_MANIFEST_SIZE  (1024UL * 1024)
#define DIOSIX_NET_MAX_FRAME_SIZE 1536UL

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
    unsigned long child_id;
    unsigned long child_gpa;
    unsigned long parent_gpa;
    unsigned long size;
    unsigned long flags;
};

struct unmap_child_mem_args {
    unsigned long parent_gpa;
    unsigned long size;
};

struct start_args {
    unsigned long child_id;
    unsigned long entry_point;
    unsigned long dtb_ptr;
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
    unsigned long cid;
    uint32_t event_type;
    uint32_t exit_code;
    uint64_t _reserved;
};

struct wait_event_args {
    unsigned long target_cid;
    unsigned long flags;
    struct diosix_event event;
};

struct quota_args {
    unsigned long target_cid;
    unsigned long max_ram_pages;
    unsigned long max_vcpus;
    unsigned long max_child_depth;
    unsigned long max_descendants;
};

struct manifest_args {
    unsigned long target_cid;
    unsigned long data_ptr;
    unsigned long max_len;
    unsigned long actual_len;
};

struct run_args {
    unsigned long child_id;
    unsigned long elf_ptr;
    unsigned long elf_size;
    unsigned long dtb_ptr;
    unsigned long dtb_size;
    unsigned long target_arch;
    unsigned long flags;
};

struct terminate_args {
    unsigned long target_id;
    unsigned long exit_code;
};

struct guest_info {
    unsigned long guest_id;
    unsigned long parent_id;
    unsigned char is_trusted;
    unsigned char is_root;
    unsigned char target_arch;
    unsigned char assigned_cid;
    unsigned long vcpus;
    unsigned long self_ram_pages;
    unsigned long used_vcpus;
    unsigned long max_vcpus;
    unsigned long used_ram_pages;
    unsigned long max_ram_pages;
    unsigned long child_count;
};

long diosix_ioctl_governance(unsigned int cmd, unsigned long arg);
int init_diosix_net(void);
void cleanup_diosix_net(void);

#endif /* DIOSIX_DRIVER_H */
