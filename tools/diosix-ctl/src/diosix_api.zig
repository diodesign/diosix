// Diosix Guest Control API and ABI definitions
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const interface = @import("interface").sbi;

// Re-export canonical SBI ABI definitions from hypervisor/interface/sbi.zig
pub const EXT_DIOSIX: usize = interface.EXT.DIOSIX;

pub const CID_PARENT: usize = interface.CID_PARENT;
pub const CID_SELF: usize = interface.CID_SELF;
pub const CID_FIRST_CHILD: usize = interface.CID_FIRST_CHILD;

pub const TargetArch = interface.TargetArch;
pub const DIOSIX_FUNC = interface.DIOSIX;
pub const HypervisorFeature = interface.HypervisorFeature;
pub const HypervisorInfo = interface.HypervisorInfo;
pub const EventType = interface.EventType;
pub const Event = interface.Event;
pub const DiosixEvent = interface.Event;
pub const WaitEventArgs = interface.WaitEventArgs;
pub const SbiResult = interface.Result;
pub const GuestInfo = interface.GuestInfo;
pub const SpawnFlags = interface.SpawnFlags;
pub const ForkFlags = interface.ForkFlags;
pub const SpawnArgs = interface.SpawnArgs;
pub const TerminateArgs = interface.TerminateArgs;
pub const QuotaArgs = interface.QuotaArgs;
pub const IpcSendArgs = interface.IpcSendArgs;
pub const IpcRecvArgs = interface.IpcRecvArgs;
pub const ManifestArgs = interface.ManifestArgs;

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
pub const IOCTL_GET_MANIFEST: u32 = IOCTL_BASE + 12;
pub const IOCTL_SET_MANIFEST: u32 = IOCTL_BASE + 13;

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

    pub fn getManifest(self: *DiosixClient, target_cid: usize, buffer: []u8) !usize {
        const fd = try self.getFd();
        var args = ManifestArgs{
            .target_cid = target_cid,
            .data_ptr = @intFromPtr(buffer.ptr),
            .max_len = buffer.len,
            .actual_len = 0,
        };
        const rc = linux.ioctl(fd, IOCTL_GET_MANIFEST, @intFromPtr(&args));
        const signed_rc: isize = @bitCast(rc);
        if (signed_rc == EPERM_NEG or signed_rc == EACCES_NEG) return error.PermissionDenied;
        if (signed_rc < 0) return error.HypercallFailed;
        return args.actual_len;
    }

    pub fn setManifest(self: *DiosixClient, target_cid: usize, data: []const u8) !void {
        const fd = try self.getFd();
        var args = ManifestArgs{
            .target_cid = target_cid,
            .data_ptr = @intFromPtr(data.ptr),
            .max_len = data.len,
            .actual_len = 0,
        };
        const rc = linux.ioctl(fd, IOCTL_SET_MANIFEST, @intFromPtr(&args));
        const signed_rc: isize = @bitCast(rc);
        if (signed_rc == EPERM_NEG or signed_rc == EACCES_NEG) return error.PermissionDenied;
        if (signed_rc < 0) return error.HypercallFailed;
    }
};

