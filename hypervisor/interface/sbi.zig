// RISC-V SBI definitions shareable between hypervisor and guests.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub const SPEC_VERSION: usize = 0x02000000; // Specification v2.0.

pub const IMPL_ID: usize = 5; // Diosix official implementation ID.
pub const IMPL_VERSION: usize = 1;

// SBI error codes.
pub const SUCCESS: isize = 0;
pub const ERR_FAILED: isize = -1;
pub const ERR_NOT_SUPPORTED: isize = -2;
pub const ERR_INVALID_PARAM: isize = -3;
pub const ERR_DENIED: isize = -4;
pub const ERR_INVALID_ADDRESS: isize = -5;
pub const ERR_ALREADY_AVAILABLE: isize = -6;

// SBI extension IDs.
pub const EXT = struct {
    pub const BASE = 0x10;
    pub const TIME = 0x54494d45;
    pub const RFENCE = 0x52464e43;
    pub const HSM = 0x48534d;
    pub const SRST = 0x53525354;
    pub const DBCN = 0x4442434e;
    pub const IPI = 0x735049;
    pub const DIOSIX = 0x0a000005;

    // Legacy extensions.
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

// Base extension function IDs.
pub const BASE = struct {
    pub const GET_SPEC_VERSION = 0;
    pub const GET_IMPL_ID = 1;
    pub const GET_IMPL_VERSION = 2;
    pub const PROBE_EXTENSION = 3;
    pub const GET_MVENDORID = 4;
    pub const GET_MARCHID = 5;
    pub const GET_MIMPID = 6;
};

// Diosix extension function IDs.
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
    pub const SEAL_CHARTER = 19;
    pub const RATIFY_CHARTER = 20;
    pub const WHISPER_SEND = 21;
    pub const WHISPER_RECV = 22;
    pub const RESET_STEWARD = 23;
    pub const REQUEST_ROOT_FAILOVER = 24;
    pub const CONSOLE_WRITE = 25;
    pub const CONSOLE_READ = 26;
};

pub const CID_PARENT: u64 = 0;
pub const CID_SELF: u64 = 1;
pub const CID_FIRST_CHILD: u64 = 2;

pub const MAX_CHILD_PCPU_QUOTA_PCT: u32 = 90;
pub const DEFAULT_RETAINED_PCPU_PCT: u32 = 10;
pub const DEFAULT_CHILD_PCPU_QUOTA_PCT: u32 = 20;
pub const MAX_GUEST_VCPUS: u32 = 4096;

pub const DEFAULT_VERSION_MAJOR: u16 = 26;
pub const DEFAULT_VERSION_MINOR: u16 = 1;
pub const DEFAULT_VERSION_PATCH: u16 = 0;
pub const BUILD_COMMIT_LEN: usize = 16;
pub const HOST_CPU_ISA_LEN: usize = 32;
pub const BUILD_DESC_LEN: usize = 192;
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
    pub const RELEASE_STABLE: u64 = 1 << 5;
    pub const CHARTER_SEALED: u64 = 1 << 6;
};

pub const HypervisorInfo = extern struct {
    abi_version_major: u16 = 0,
    abi_version_minor: u16 = 2,
    abi_version_patch: u16 = 0,
    version_major: u16 = DEFAULT_VERSION_MAJOR,
    version_minor: u16 = DEFAULT_VERSION_MINOR,
    version_patch: u16 = DEFAULT_VERSION_PATCH,
    _reserved1: u32 = 0,
    build_commit: [BUILD_COMMIT_LEN]u8 = @splat(0),

    features: u64 = 0,
    host_physical_cores: u32 = 0,
    host_timer_freq_hz: u32 = HOST_TIMER_FREQ_HZ,
    host_total_ram_kb: u64 = 0,
    host_free_ram_kb: u64 = 0,
    hv_reserved_bytes: u64 = 0,
    hv_heap_free_bytes: u64 = 0,
    host_cpu_isa: [HOST_CPU_ISA_LEN]u8 = @splat(0),
    build_desc: [BUILD_DESC_LEN]u8 = @splat(0),
};

pub const GuestInfo = extern struct {
    guest_id: u64,
    parent_id: u64,
    is_trusted: u8,
    is_root: u8,
    target_arch: u8, // TargetArch enum value.
    assigned_cid: u8 = 0,
    cpu_khz_ticks: u32 = 0,
    vcpus: u64,
    self_ram_pages: u64,
    used_vcpus: u64,
    max_vcpus: u64,
    used_ram_pages: u64,
    max_ram_pages: u64,
    child_count: u64,
    pcpu_quota_pct: u32 = 100,
    delegated_pcpu_pct: u32 = 0,
    delegated_ram_pages: u64 = 0,
};

pub const EventType = enum(u32) {
    none = 0,
    child_terminated = 1,
    child_stopped = 2,
    child_started = 3,
    child_memory_pressure = 4,
};

pub const Event = extern struct {
    cid: u64,
    event_type: u32,
    exit_code: u32,
    _reserved: u64 = 0,
};

pub const RunFlags = struct {
    pub const TRUSTED: u64 = 1 << 0;
    pub const STEWARD: u64 = 1 << 1;
    pub const STANDBY_ROOT: u64 = 1 << 2;
    pub const CONFIDENTIAL: u64 = 1 << 3;
};

pub const CHARTER_HASH_LEN: usize = 32;

pub const CharterArgs = extern struct {
    charter_hash: [CHARTER_HASH_LEN]u8 = @splat(0),
    quorum_required: u16 = 2,
    quorum_total: u16 = 3,
    standby_replicas: u16 = 1,
    is_sealed: u8 = 0,
    _reserved: u8 = 0,
    ratified_mask: u64 = 0,
    approved_target_cid: u64 = 0,
    failover_epoch: u64 = 0,
};

pub const RunArgs = extern struct {
    child_id: u64,
    elf_ptr: u64,
    elf_size: u64,
    dtb_ptr: u64,
    dtb_size: u64,
    target_arch: u64,
    flags: u64 = 0,
};

pub const TerminateArgs = extern struct {
    target_id: u64,
    exit_code: u64,
};

pub const WAIT_EVENT_FLAG_NOHANG: u64 = 1 << 0;

pub const WaitEventArgs = extern struct {
    target_cid: u64,
    flags: u64,
    event: Event = std.mem.zeroes(Event),
};

pub const QuotaArgs = extern struct {
    target_cid: u64 = 0,
    max_ram_pages: u64 = 0,
    max_vcpus: u64 = 0,
    max_child_depth: u64 = 0,
    max_descendants: u64 = 0,
    pcpu_quota_pct: u64 = 0,
    logical_ram_pages: u64 = 0,
};

pub const ManifestArgs = extern struct {
    target_cid: u64,
    data_ptr: u64,
    max_len: u64,
    actual_len: u64 = 0,
};

pub const MAX_CONSOLE_IO_BYTES: usize = 4096;

pub const ConsoleArgs = extern struct {
    target_cid: u64,
    data_ptr: u64,
    max_len: u64,
    actual_len: u64 = 0,
};

pub const MapChildMemArgs = extern struct {
    child_id: u64,
    child_gpa: u64,
    parent_gpa: u64,
    size: u64,
    flags: u64,
};

pub const UnmapChildMemArgs = extern struct {
    parent_gpa: u64,
    size: u64,
};

pub const StartArgs = extern struct {
    child_id: u64,
    entry_point: u64,
    dtb_ptr: u64,
};

// Debug Console extension function IDs.
pub const DBCN = struct {
    pub const CONSOLE_WRITE = 0;
    pub const CONSOLE_READ = 1;
    pub const CONSOLE_WRITE_BYTE = 2;
};

// HSM extension function IDs and hart status codes.
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

// SRST extension reset types and function IDs.
pub const SRST = struct {
    pub const SYSTEM_RESET = 0;

    pub const TYPE_SHUTDOWN = 0;
    pub const TYPE_COLD_REBOOT = 1;
    pub const TYPE_WARM_REBOOT = 2;
};

// SBI call result.
pub const Result = struct {
    err: isize,
    value: usize,
};

comptime {
    std.debug.assert(@sizeOf(HypervisorInfo) == 304);
    std.debug.assert(@sizeOf(GuestInfo) == 96);
    std.debug.assert(@sizeOf(Event) == 24);
    std.debug.assert(@sizeOf(CharterArgs) == 64);
    std.debug.assert(@sizeOf(RunArgs) == 56);
    std.debug.assert(@sizeOf(TerminateArgs) == 16);
    std.debug.assert(@sizeOf(WaitEventArgs) == 40);
    std.debug.assert(@sizeOf(QuotaArgs) == 56);
    std.debug.assert(@sizeOf(ManifestArgs) == 32);
    std.debug.assert(@sizeOf(ConsoleArgs) == 32);
    std.debug.assert(@sizeOf(MapChildMemArgs) == 40);
    std.debug.assert(@sizeOf(UnmapChildMemArgs) == 16);
    std.debug.assert(@sizeOf(StartArgs) == 24);
}

test "SBI interface structures and extension IDs" {
    std.testing.refAllDecls(@This());
    const testing = std.testing;

    // Verify cross-ABI struct sizes.
    try testing.expectEqual(@as(usize, 96), @sizeOf(GuestInfo));
    try testing.expectEqual(@as(usize, 304), @sizeOf(HypervisorInfo));
    try testing.expectEqual(
        @as(usize, 10),
        @offsetOf(HypervisorInfo, "version_patch"),
    );
    try testing.expectEqual(@as(usize, 24), @sizeOf(Event));
    try testing.expectEqual(@as(usize, 64), @sizeOf(CharterArgs));
    try testing.expectEqual(@as(usize, 56), @sizeOf(RunArgs));
    try testing.expectEqual(@as(usize, 16), @sizeOf(TerminateArgs));
    try testing.expectEqual(@as(usize, 40), @sizeOf(WaitEventArgs));
    try testing.expectEqual(@as(usize, 56), @sizeOf(QuotaArgs));
    try testing.expectEqual(@as(usize, 32), @sizeOf(ManifestArgs));
    try testing.expectEqual(@as(usize, 32), @sizeOf(ConsoleArgs));
    try testing.expectEqual(@as(usize, 40), @sizeOf(MapChildMemArgs));
    try testing.expectEqual(@as(usize, 16), @sizeOf(UnmapChildMemArgs));
    try testing.expectEqual(@as(usize, 24), @sizeOf(StartArgs));

    // Verify Extension IDs and Function IDs.
    try testing.expectEqual(@as(usize, 0x10), EXT.BASE);
    try testing.expectEqual(@as(usize, 0x0a000005), EXT.DIOSIX);
    try testing.expectEqual(@as(usize, 0x4442434e), EXT.DBCN);
    try testing.expectEqual(@as(usize, 0x48534d), EXT.HSM);
    try testing.expectEqual(@as(usize, 0x53525354), EXT.SRST);
    try testing.expectEqual(@as(usize, 19), DIOSIX.SEAL_CHARTER);
    try testing.expectEqual(@as(usize, 24), DIOSIX.REQUEST_ROOT_FAILOVER);
    try testing.expectEqual(@as(u64, 1 << 5), HypervisorFeature.RELEASE_STABLE);
    try testing.expectEqual(@as(u64, 1 << 6), HypervisorFeature.CHARTER_SEALED);
}
