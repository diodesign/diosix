// Diosix Guest Control API and ABI definitions
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;

pub const EXT_DIOSIX: usize = 0x0A000005;

pub const CID_PARENT: usize = 0;
pub const CID_SELF: usize = 1;
pub const CID_FIRST_CHILD: usize = 2;

pub const TargetArch = enum(u8) {
    riscv64 = 0,
    riscv32 = 1,
    aarch64 = 2,
    x86_64 = 3,
};

pub const DIOSIX_FUNC = struct {
    pub const TERMINATE: usize = 0;
    pub const EXIT: usize = 0;
    pub const YIELD: usize = 1;
    pub const FORK: usize = 2;
    pub const DROP_TRUST: usize = 3;
    pub const SPAWN: usize = 4;
    pub const GET_INFO: usize = 5;
    pub const SET_QUOTA: usize = 6;
    pub const IPC_SEND: usize = 7;
    pub const IPC_RECV: usize = 8;
    pub const POLL_EVENT: usize = 9;
    pub const GET_HV_INFO: usize = 10;
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
    abi_version_major: u16,
    abi_version_minor: u16,
    abi_version_patch: u16,
    version_major: u16,
    version_minor: u16,
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

pub const DiosixEvent = Event;

pub const WaitEventArgs = extern struct {
    target_cid: usize,
    flags: usize,
    event: Event = std.mem.zeroes(Event),
};

pub const SbiResult = struct {
    err: isize,
    value: usize,
};

pub const GuestInfo = extern struct {
    guest_id: usize,
    parent_id: usize,
    is_trusted: u8,
    is_root: u8,
    target_arch: u8, // TargetArch enum value
    _reserved: u8 = 0,
    used_ram_pages: usize,
    max_ram_pages: usize,
    used_vcpus: usize,
    max_vcpus: usize,
    child_count: usize,
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

pub const TerminateArgs = extern struct {
    target_id: usize,
    exit_code: usize,
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

// IOCTL command definitions for /dev/diosix
pub const IOCTL_BASE: u32 = 0x1000;
pub const IOCTL_FORK: u32         = IOCTL_BASE + 1;
pub const IOCTL_DROP_TRUST: u32   = IOCTL_BASE + 2;
pub const IOCTL_SPAWN: u32        = IOCTL_BASE + 3;
pub const IOCTL_GET_INFO: u32     = IOCTL_BASE + 4;
pub const IOCTL_SET_QUOTA: u32    = IOCTL_BASE + 5;
pub const IOCTL_TERMINATE: u32    = IOCTL_BASE + 6;
pub const IOCTL_EXIT: u32         = IOCTL_TERMINATE;
pub const IOCTL_KILL: u32         = IOCTL_TERMINATE;
pub const IOCTL_YIELD: u32        = IOCTL_BASE + 7;
pub const IOCTL_WAIT_EVENT: u32   = IOCTL_BASE + 8;
pub const IOCTL_IPC_SEND: u32     = IOCTL_BASE + 9;
pub const IOCTL_IPC_RECV: u32     = IOCTL_BASE + 10;
pub const IOCTL_GET_HV_INFO: u32  = IOCTL_BASE + 11;

const EPERM_NEG: isize = -@as(isize, @intFromEnum(linux.E.PERM));
const EACCES_NEG: isize = -@as(isize, @intFromEnum(linux.E.ACCES));
const EAGAIN_NEG: isize = -@as(isize, @intFromEnum(linux.E.AGAIN));

pub const DiosixClient = struct {
    dev_fd: ?i32,
    open_err: ?isize,

    pub fn init() DiosixClient {
        const path = "/dev/diosix";
        const rc = linux.open(path, .{ .ACCMODE = .RDWR }, 0);
        const signed_rc: isize = @bitCast(rc);
        if (signed_rc >= 0) {
            return .{ .dev_fd = @intCast(signed_rc), .open_err = null };
        }
        return .{ .dev_fd = null, .open_err = signed_rc };
    }

    pub fn deinit(self: *DiosixClient) void {
        if (self.dev_fd) |fd| {
            _ = linux.close(fd);
            self.dev_fd = null;
        }
    }

    fn getFd(self: *DiosixClient) !i32 {
        if (self.dev_fd) |fd| return fd;
        if (self.open_err) |err| {
            if (err == EPERM_NEG or err == EACCES_NEG) return error.PermissionDenied;
        }
        return error.DeviceNotFound;
    }

    /// Perform a hypercall via /dev/diosix ioctl
    pub fn fork(self: *DiosixClient, flags: usize) !usize {
        const fd = try self.getFd();
        var child_id: usize = flags;
        const rc = linux.ioctl(fd, IOCTL_FORK, @intFromPtr(&child_id));
        const signed_rc: isize = @bitCast(rc);
        if (signed_rc == EPERM_NEG or signed_rc == EACCES_NEG) return error.PermissionDenied;
        if (signed_rc < 0) return error.HypercallFailed;
        return if (child_id > 0) child_id else @intCast(signed_rc);
    }

    pub fn dropTrust(self: *DiosixClient) !void {
        const fd = try self.getFd();
        const rc = linux.ioctl(fd, IOCTL_DROP_TRUST, 0);
        const signed_rc: isize = @bitCast(rc);
        if (signed_rc == EPERM_NEG or signed_rc == EACCES_NEG) return error.PermissionDenied;
        if (signed_rc < 0) return error.HypercallFailed;
    }

    pub fn getInfo(self: *DiosixClient) !GuestInfo {
        const fd = try self.getFd();
        var info: GuestInfo = undefined;
        const rc = linux.ioctl(fd, IOCTL_GET_INFO, @intFromPtr(&info));
        const signed_rc: isize = @bitCast(rc);
        if (signed_rc == EPERM_NEG or signed_rc == EACCES_NEG) return error.PermissionDenied;
        if (signed_rc < 0) return error.HypercallFailed;
        return info;
    }

    pub fn spawn(self: *DiosixClient, child_id: usize, elf_data: []const u8, dtb_data: []const u8, arch: usize, flags: usize) !usize {
        const fd = try self.getFd();
        var args = SpawnArgs{
            .child_id = child_id,
            .elf_ptr = @intFromPtr(elf_data.ptr),
            .elf_size = elf_data.len,
            .dtb_ptr = if (dtb_data.len > 0) @intFromPtr(dtb_data.ptr) else 0,
            .dtb_size = dtb_data.len,
            .target_arch = arch,
            .flags = flags,
        };
        const rc = linux.ioctl(fd, IOCTL_SPAWN, @intFromPtr(&args));
        const signed_rc: isize = @bitCast(rc);
        if (signed_rc == EPERM_NEG or signed_rc == EACCES_NEG) return error.PermissionDenied;
        if (signed_rc < 0) return error.HypercallFailed;
        return if (args.child_id > 0) args.child_id else @intCast(signed_rc);
    }

    pub fn terminate(self: *DiosixClient, target_id: usize, exit_code: usize) !void {
        const fd = try self.getFd();
        var args = TerminateArgs{
            .target_id = target_id,
            .exit_code = exit_code,
        };
        const rc = linux.ioctl(fd, IOCTL_TERMINATE, @intFromPtr(&args));
        const signed_rc: isize = @bitCast(rc);
        if (signed_rc == EPERM_NEG or signed_rc == EACCES_NEG) return error.PermissionDenied;
        if (signed_rc < 0) return error.HypercallFailed;
    }

    pub fn exit(self: *DiosixClient, code: usize) void {
        _ = self.terminate(0, code) catch {};
    }

    pub fn waitEvent(self: *DiosixClient, target_cid: usize, nohang: bool) !?Event {
        const fd = try self.getFd();
        var args = WaitEventArgs{
            .target_cid = target_cid,
            .flags = if (nohang) 1 else 0,
            .event = std.mem.zeroes(Event),
        };
        const rc = linux.ioctl(fd, IOCTL_WAIT_EVENT, @intFromPtr(&args));
        const signed_rc: isize = @bitCast(rc);
        if (signed_rc == EPERM_NEG or signed_rc == EACCES_NEG) return error.PermissionDenied;
        if (signed_rc == EAGAIN_NEG) return null; // -EAGAIN on non-blocking check
        if (signed_rc < 0) return error.HypercallFailed;
        return args.event;
    }

    pub fn setQuota(self: *DiosixClient, target_cid: usize, ram_pages: usize, vcpus: usize, depth: usize, descendants: usize) !void {
        const fd = try self.getFd();
        var args = QuotaArgs{
            .target_cid = target_cid,
            .max_ram_pages = ram_pages,
            .max_vcpus = vcpus,
            .max_child_depth = depth,
            .max_descendants = descendants,
        };
        const rc = linux.ioctl(fd, IOCTL_SET_QUOTA, @intFromPtr(&args));
        const signed_rc: isize = @bitCast(rc);
        if (signed_rc == EPERM_NEG or signed_rc == EACCES_NEG) return error.PermissionDenied;
        if (signed_rc < 0) return error.HypercallFailed;
    }

    pub fn sendIpc(self: *DiosixClient, target_cid: usize, data: []const u8) !void {
        const fd = try self.getFd();
        var args = IpcSendArgs{
            .target_cid = target_cid,
            .data_ptr = @intFromPtr(data.ptr),
            .data_len = data.len,
        };
        const rc = linux.ioctl(fd, IOCTL_IPC_SEND, @intFromPtr(&args));
        const signed_rc: isize = @bitCast(rc);
        if (signed_rc == EPERM_NEG or signed_rc == EACCES_NEG) return error.PermissionDenied;
        if (signed_rc < 0) return error.HypercallFailed;
    }

    pub const IpcReceivedMessage = struct {
        sender_cid: usize,
        data: []u8,
    };

    pub fn recvIpc(self: *DiosixClient, sender_cid: usize, buffer: []u8) !?IpcReceivedMessage {
        const fd = try self.getFd();
        var args = IpcRecvArgs{
            .sender_cid = sender_cid,
            .data_ptr = @intFromPtr(buffer.ptr),
            .max_len = buffer.len,
            .actual_len = 0,
            .actual_sender_cid = 0,
        };
        const rc = linux.ioctl(fd, IOCTL_IPC_RECV, @intFromPtr(&args));
        const signed_rc: isize = @bitCast(rc);
        if (signed_rc == EPERM_NEG or signed_rc == EACCES_NEG) return error.PermissionDenied;
        if (signed_rc <= 0) return null; // 0 = no message
        return .{
            .sender_cid = args.actual_sender_cid,
            .data = buffer[0..args.actual_len],
        };
    }

    pub fn getHypervisorInfo(self: *DiosixClient) !HypervisorInfo {
        const fd = try self.getFd();
        var info = std.mem.zeroes(HypervisorInfo);
        const rc = linux.ioctl(fd, IOCTL_GET_HV_INFO, @intFromPtr(&info));
        const signed_rc: isize = @bitCast(rc);
        if (signed_rc == EPERM_NEG or signed_rc == EACCES_NEG) return error.PermissionDenied;
        if (signed_rc < 0) return error.HypercallFailed;
        return info;
    }
};

