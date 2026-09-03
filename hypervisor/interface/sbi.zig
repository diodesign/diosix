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
    pub const DROP_TRUST = 3;
    pub const RUN = 4;
    pub const GET_INFO = 5;
    pub const SET_QUOTA = 6;
    pub const POLL_EVENT = 9;
    pub const GET_HV_INFO = 10;
    pub const GET_MANIFEST = 11;
    pub const SET_MANIFEST = 12;
    pub const MAP_CHILD_MEM = 13;
    pub const UNMAP_CHILD_MEM = 14;
    pub const START = 15;
    pub const NET_SEND = 16;
    pub const NET_RECV = 17;
    pub const NET_POLL = 18;
};

pub const CID_PARENT: usize = 0;
pub const CID_SELF: usize = 1;
pub const CID_FIRST_CHILD: usize = 2;

pub const DEFAULT_VERSION_MAJOR: u16 = 26;
pub const DEFAULT_VERSION_MINOR: u16 = 1;
pub const BUILD_COMMIT_LEN: usize = 16;
pub const HOST_TIMER_FREQ_HZ: u32 = 10_000_000;

pub const TargetArch = enum(u8) {
    riscv64 = 0,
    riscv32 = 1,
    aarch64 = 2,
    x86_64 = 3,
};

pub const HypervisorFeature = struct {
    pub const HARDWARE_VIRT: u64 = 1 << 0;
    pub const STAGE2_PAGING: u64 = 1 << 1;
    pub const DYNAREC: u64 = 1 << 2;
    pub const VIRTIO_VSOCK: u64 = 1 << 3;
    pub const IOMMU: u64 = 1 << 4;
};

pub const HypervisorInfo = extern struct {
    abi_version_major: u16 = 0,
    abi_version_minor: u16 = 2,
    abi_version_patch: u16 = 0,
    version_major: u16 = DEFAULT_VERSION_MAJOR,
    version_minor: u16 = DEFAULT_VERSION_MINOR,
    _reserved0: u16 = 0,
    _reserved1: u32 = 0,
    build_commit: [BUILD_COMMIT_LEN]u8 = std.mem.zeroes([BUILD_COMMIT_LEN]u8),

    features: u64 = 0,
    host_physical_cores: u32 = 0,
    host_timer_freq_hz: u32 = HOST_TIMER_FREQ_HZ,
    host_total_ram_kb: u64 = 0,
    host_free_ram_kb: u64 = 0,
};

pub const GuestInfo = extern struct {
    guest_id: usize,
    parent_id: usize,
    is_trusted: u8,
    is_root: u8,
    target_arch: u8, // TargetArch enum value
    assigned_cid: u8 = 0,
    vcpus: usize,
    self_ram_pages: usize,
    used_vcpus: usize,
    max_vcpus: usize,
    used_ram_pages: usize,
    max_ram_pages: usize,
    child_count: usize,
};

pub const EventType = enum(u32) {
    none = 0,
    child_terminated = 1,
    child_stopped = 2,
    child_started = 3,
};

pub const Event = extern struct {
    cid: usize,
    event_type: u32,
    exit_code: u32,
    _reserved: u64 = 0,
};

pub const RunFlags = struct {
    pub const TRUSTED: usize = 1 << 0;
};

pub const RunArgs = extern struct {
    child_id: usize,
    elf_ptr: usize,
    elf_size: usize,
    dtb_ptr: usize,
    dtb_size: usize,
    target_arch: usize,
    flags: usize = 0,
};

pub const TerminateArgs = extern struct {
    target_id: usize,
    exit_code: usize,
};

pub const WaitEventArgs = extern struct {
    target_cid: usize,
    flags: usize,
    event: Event = std.mem.zeroes(Event),
};

pub const QuotaArgs = extern struct {
    target_cid: usize,
    max_ram_pages: usize,
    max_vcpus: usize,
    max_child_depth: usize,
    max_descendants: usize,
};

pub const ManifestArgs = extern struct {
    target_cid: usize,
    data_ptr: usize,
    max_len: usize,
    actual_len: usize = 0,
};

pub const MapChildMemArgs = extern struct {
    child_id: usize,
    child_gpa: usize,
    parent_gpa: usize,
    size: usize,
    flags: usize,
};

pub const UnmapChildMemArgs = extern struct {
    parent_gpa: usize,
    size: usize,
};

pub const StartArgs = extern struct {
    child_id: usize,
    entry_point: usize,
    dtb_ptr: usize,
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

test "SBI interface structures and extension IDs" {
    const testing = std.testing;

    // Verify GuestInfo C-ABI compatibility
    try testing.expectEqual(@sizeOf(usize) * 10, @sizeOf(GuestInfo));

    // Verify HypervisorInfo structure size
    try testing.expectEqual(64, @sizeOf(HypervisorInfo));

    // Verify Extension IDs
    try testing.expectEqual(@as(usize, 0x10), EXT.BASE);
    try testing.expectEqual(@as(usize, 0x0A000005), EXT.DIOSIX);
    try testing.expectEqual(@as(usize, 0x4442434E), EXT.DBCN);
    try testing.expectEqual(@as(usize, 0x48534D), EXT.HSM);
    try testing.expectEqual(@as(usize, 0x53525354), EXT.SRST);
}
