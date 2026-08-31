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
pub const RunFlags = interface.RunFlags;
pub const SpawnFlags = interface.RunFlags;
pub const RunArgs = interface.RunArgs;
pub const TerminateArgs = interface.TerminateArgs;
pub const QuotaArgs = interface.QuotaArgs;
pub const ManifestArgs = interface.ManifestArgs;
pub const MapChildMemArgs = interface.MapChildMemArgs;
pub const UnmapChildMemArgs = interface.UnmapChildMemArgs;
pub const StartArgs = interface.StartArgs;

// IOCTL command definitions for /dev/diosix
pub const IOCTL_BASE: u32 = 0x1000;
pub const IOCTL_DROP_TRUST: u32 = IOCTL_BASE + 2;
pub const IOCTL_RUN: u32 = IOCTL_BASE + 3;
pub const IOCTL_SPAWN: u32 = IOCTL_RUN;
pub const IOCTL_GET_INFO: u32 = IOCTL_BASE + 4;
pub const IOCTL_SET_QUOTA: u32 = IOCTL_BASE + 5;
pub const IOCTL_TERMINATE: u32 = IOCTL_BASE + 6;
pub const IOCTL_EXIT: u32 = IOCTL_TERMINATE;
pub const IOCTL_KILL: u32 = IOCTL_TERMINATE;
pub const IOCTL_YIELD: u32 = IOCTL_BASE + 7;
pub const IOCTL_WAIT_EVENT: u32 = IOCTL_BASE + 8;
pub const IOCTL_GET_HV_INFO: u32 = IOCTL_BASE + 11;
pub const IOCTL_GET_MANIFEST: u32 = IOCTL_BASE + 12;
pub const IOCTL_SET_MANIFEST: u32 = IOCTL_BASE + 13;
pub const IOCTL_MAP_CHILD_MEM: u32 = IOCTL_BASE + 14;
pub const IOCTL_UNMAP_CHILD_MEM: u32 = IOCTL_BASE + 15;
pub const IOCTL_START: u32 = IOCTL_BASE + 16;

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

    pub fn run(self: *DiosixClient, child_id: usize, elf_data: []const u8, dtb_data: []const u8, arch: usize, flags: usize) !usize {
        const fd = try self.getFd();
        var args = RunArgs{
            .child_id = child_id,
            .elf_ptr = @intFromPtr(elf_data.ptr),
            .elf_size = elf_data.len,
            .dtb_ptr = if (dtb_data.len > 0) @intFromPtr(dtb_data.ptr) else 0,
            .dtb_size = dtb_data.len,
            .target_arch = arch,
            .flags = flags,
        };
        const rc = linux.ioctl(fd, IOCTL_RUN, @intFromPtr(&args));
        const signed_rc: isize = @bitCast(rc);
        if (signed_rc == EPERM_NEG or signed_rc == EACCES_NEG) return error.PermissionDenied;
        if (signed_rc < 0) return error.HypercallFailed;
        return if (args.child_id > 0) args.child_id else @intCast(signed_rc);
    }

    pub fn spawn(self: *DiosixClient, child_id: usize, elf_data: []const u8, dtb_data: []const u8, arch: usize, flags: usize) !usize {
        return self.run(child_id, elf_data, dtb_data, arch, flags);
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

    pub fn mapChildMemory(self: *DiosixClient, target_cid: usize, child_gpa: usize, parent_gpa: usize, size: usize, flags: usize) ![]u8 {
        const fd = try self.getFd();
        var args = MapChildMemArgs{
            .child_id = target_cid,
            .child_gpa = child_gpa,
            .parent_gpa = parent_gpa,
            .size = size,
            .flags = flags,
        };
        const rc = linux.ioctl(fd, IOCTL_MAP_CHILD_MEM, @intFromPtr(&args));
        const signed_rc: isize = @bitCast(rc);
        if (signed_rc == EPERM_NEG or signed_rc == EACCES_NEG) return error.PermissionDenied;
        if (signed_rc < 0) return error.HypercallFailed;

        const mmap_res = linux.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, @intCast(args.parent_gpa));
        const mmap_signed: isize = @bitCast(mmap_res);
        if (mmap_signed < 0) return error.OutOfMemory;
        const ptr: [*]u8 = @ptrFromInt(mmap_res);
        return ptr[0..size];
    }

    pub fn unmapChildMemory(self: *DiosixClient, mapped_slice: []u8, parent_gpa: usize) !void {
        _ = linux.munmap(mapped_slice.ptr, mapped_slice.len);
        const fd = try self.getFd();
        var args = UnmapChildMemArgs{
            .parent_gpa = parent_gpa,
            .size = mapped_slice.len,
        };
        const rc = linux.ioctl(fd, IOCTL_UNMAP_CHILD_MEM, @intFromPtr(&args));
        const signed_rc: isize = @bitCast(rc);
        if (signed_rc == EPERM_NEG or signed_rc == EACCES_NEG) return error.PermissionDenied;
        if (signed_rc < 0) return error.HypercallFailed;
    }

    pub fn startGuest(self: *DiosixClient, target_cid: usize, entry_point: usize, dtb_ptr: usize) !usize {
        const fd = try self.getFd();
        var args = StartArgs{
            .child_id = target_cid,
            .entry_point = entry_point,
            .dtb_ptr = dtb_ptr,
        };
        const rc = linux.ioctl(fd, IOCTL_START, @intFromPtr(&args));
        const signed_rc: isize = @bitCast(rc);
        if (signed_rc == EPERM_NEG or signed_rc == EACCES_NEG) return error.PermissionDenied;
        if (signed_rc < 0) return error.HypercallFailed;
        return @intCast(signed_rc);
    }
};
