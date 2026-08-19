// RISC-V SBI definitions shareable between hypervisor and guests
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub const SPEC_VERSION: usize = 0x02000000; // v2.0

pub const IMPL_ID: usize = 5; // Diosix official implementation ID
pub const IMPL_VERSION: usize = 1;

// SBI Error Codes
pub const SUCCESS: isize = 0;
pub const ERR_FAILED: isize = -1;
pub const ERR_NOT_SUPPORTED: isize = -2;
pub const ERR_INVALID_PARAM: isize = -3;
pub const ERR_DENIED: isize = -4;
pub const ERR_INVALID_ADDRESS: isize = -5;
pub const ERR_ALREADY_AVAILABLE: isize = -6;

// SBI Extension IDs
pub const EXT = struct {
    pub const BASE = 0x10;
    pub const TIME = 0x54494d45;
    pub const RFENCE = 0x52464e43;
    pub const HSM = 0x48534d;
    pub const SRST = 0x53525354;
    pub const DBCN = 0x4442434e;
    pub const IPI = 0x735049;
    pub const DIOSIX = 0x0A000005;

    // Legacy Extensions
    pub const LEGACY_SET_TIMER = 0x0;
    pub const LEGACY_CONSOLE_PUTCHAR = 0x1;
    pub const LEGACY_CONSOLE_GETCHAR = 0x2;
    pub const LEGACY_CLEAR_IPI = 0x3;
    pub const LEGACY_SEND_IPI = 0x4;
    pub const LEGACY_REMOTE_FENCE_I = 0x5;
    pub const LEGACY_REMOTE_SFENCE_VMA = 0x6;
    pub const LEGACY_REMOTE_SFENCE_VMA_ASID = 0x7;
    pub const LEGACY_SHUTDOWN = 0x8;
};

// Base Extension Function IDs
pub const BASE = struct {
    pub const GET_SPEC_VERSION = 0;
    pub const GET_IMPL_ID = 1;
    pub const GET_IMPL_VERSION = 2;
    pub const PROBE_EXTENSION = 3;
    pub const GET_MVENDORID = 4;
    pub const GET_MARCHID = 5;
    pub const GET_MIMPID = 6;
};

// Diosix Extension Function IDs
pub const DIOSIX = struct {
    pub const TERMINATE = 0;
    pub const EXIT = 0;
    pub const YIELD = 1;
    pub const FORK = 2;
    pub const DROP_TRUST = 3;
    pub const SPAWN = 4;
    pub const GET_INFO = 5;
    pub const SET_QUOTA = 6;
    pub const IPC_SEND = 7;
    pub const IPC_RECV = 8;
    pub const POLL_EVENT = 9;
    pub const GET_HV_INFO = 10;
};

pub const HypervisorFeature = struct {
    pub const HARDWARE_VIRT: u64 = 1 << 0;
    pub const STAGE2_PAGING: u64 = 1 << 1;
    pub const COW_FORK: u64      = 1 << 2;
    pub const DYNAREC: u64       = 1 << 3;
    pub const INTER_VM_IPC: u64  = 1 << 4;
    pub const IOMMU: u64         = 1 << 5;
};

pub const HypervisorInfo = extern struct {
    abi_version_major: u16 = 0,
    abi_version_minor: u16 = 2,
    abi_version_patch: u16 = 0,
    version_major: u16 = 26,
    version_minor: u16 = 1,
    _reserved0: u16 = 0,
    _reserved1: u32 = 0,
    build_commit: [16]u8 = std.mem.zeroes([16]u8),

    features: u64 = 0,
    host_physical_cores: u32 = 0,
    host_timer_freq_hz: u32 = 0,
    host_total_ram_kb: u64 = 0,
    host_free_ram_kb: u64 = 0,
};

pub const EventType = enum(u32) {
    none = 0,
    child_terminated = 1,
    child_stopped = 2,
    child_spawned = 3,
    ipc_message = 4,
};

pub const Event = extern struct {
    cid: usize,
    event_type: u32,
    exit_code: u32,
    _reserved: u64 = 0,
};

pub const SpawnFlags = struct {
    pub const TRUSTED: usize = 1 << 0;
};

pub const ForkFlags = struct {
    pub const UNTRUSTED: usize = 1 << 0;
};

pub const SpawnArgs = extern struct {
    child_id: usize,
    elf_ptr: usize,
    elf_size: usize,
    dtb_ptr: usize,
    dtb_size: usize,
    target_arch: usize,
    flags: usize = 0,
};

pub const QuotaArgs = extern struct {
    target_cid: usize,
    max_ram_pages: usize,
    max_vcpus: usize,
    max_child_depth: usize,
    max_descendants: usize,
};

pub const IpcSendArgs = extern struct {
    target_cid: usize,
    data_ptr: usize,
    data_len: usize,
};

pub const IpcRecvArgs = extern struct {
    sender_cid: usize,
    data_ptr: usize,
    max_len: usize,
    actual_len: usize = 0,
    actual_sender_cid: usize = 0,
};







// Debug Console Extension Function IDs
pub const DBCN = struct {
    pub const CONSOLE_WRITE = 0;
    pub const CONSOLE_READ = 1;
    pub const CONSOLE_WRITE_BYTE = 2;
};

// HSM Extension Function IDs and Hart Status Codes
pub const HSM = struct {
    pub const HART_START = 0;
    pub const HART_STOP = 1;
    pub const HART_GET_STATUS = 2;
    pub const HART_SUSPEND = 3;

    pub const STATUS_STARTED = 0;
    pub const STATUS_STOPPED = 1;
    pub const STATUS_START_PENDING = 2;
    pub const STATUS_STOP_PENDING = 3;
    pub const STATUS_SUSPENDED = 4;
};

// SRST Extension reset types and function IDs
pub const SRST = struct {
    pub const SYSTEM_RESET = 0;

    pub const TYPE_SHUTDOWN = 0;
    pub const TYPE_COLD_REBOOT = 1;
    pub const TYPE_WARM_REBOOT = 2;
};

// SBI Call Result
pub const Result = struct {
    err: isize,
    value: usize,
};
