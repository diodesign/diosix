// Diosix Guest Control API and ABI definitions.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const interface = @import("interface").sbi;
const sysconfig = @import("sysconfig.zig");

// Re-export canonical SBI ABI definitions from hypervisor/interface/sbi.zig.
pub const EXT_DIOSIX: usize = interface.EXT.DIOSIX;

pub const CID_PARENT: usize = interface.CID_PARENT;
pub const CID_SELF: usize = interface.CID_SELF;
pub const CID_FIRST_CHILD: usize = interface.CID_FIRST_CHILD;
pub const MAX_CHILD_PCPU_QUOTA_PCT: u32 = interface.MAX_CHILD_PCPU_QUOTA_PCT;
pub const DEFAULT_CHILD_PCPU_QUOTA_PCT: u32 =
    interface.DEFAULT_CHILD_PCPU_QUOTA_PCT;

pub const TargetArch = interface.TargetArch;
pub const DIOSIX_FUNC = interface.DIOSIX;
pub const BUILD_COMMIT_LEN = interface.BUILD_COMMIT_LEN;
pub const HOST_CPU_ISA_LEN = interface.HOST_CPU_ISA_LEN;
pub const BUILD_DESC_LEN = interface.BUILD_DESC_LEN;
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
pub const ConsoleArgs = interface.ConsoleArgs;
pub const MAX_CONSOLE_IO_BYTES = interface.MAX_CONSOLE_IO_BYTES;
pub const MapChildMemArgs = interface.MapChildMemArgs;
pub const UnmapChildMemArgs = interface.UnmapChildMemArgs;
pub const StartArgs = interface.StartArgs;
pub const CharterArgs = interface.CharterArgs;

// IOCTL command definitions for /dev/diosix.
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
pub const IOCTL_SEAL_CHARTER: u32 = IOCTL_BASE + 17;
pub const IOCTL_GET_CHARTER: u32 = IOCTL_BASE + 18;
pub const IOCTL_RATIFY_CHARTER: u32 = IOCTL_BASE + 19;
pub const IOCTL_RESET_STEWARD: u32 = IOCTL_BASE + 20;
pub const IOCTL_REQUEST_ROOT_FAILOVER: u32 = IOCTL_BASE + 21;
pub const IOCTL_CONSOLE_WRITE: u32 = IOCTL_BASE + 22;
pub const IOCTL_CONSOLE_READ: u32 = IOCTL_BASE + 23;

const EPERM_NEG: isize = -@as(isize, @backingInt(linux.E.PERM));
const EACCES_NEG: isize = -@as(isize, @backingInt(linux.E.ACCES));
const EAGAIN_NEG: isize = -@as(isize, @backingInt(linux.E.AGAIN));

fn checkIoctlRc(rc: usize) !isize {
    const signed_rc: isize = @bitCast(rc);
    if (signed_rc == EPERM_NEG or signed_rc == EACCES_NEG) {
        return error.PermissionDenied;
    }
    if (signed_rc < 0) return error.HypercallFailed;
    return signed_rc;
}

pub const DiosixClient = struct {
    dev_fd: ?i32,
    open_err: ?isize,

    pub fn init() DiosixClient {
        const path = sysconfig.DEFAULT_DEVICE_PATH;
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
            if (err == EPERM_NEG or err == EACCES_NEG) {
                return error.PermissionDenied;
            }
        }
        return error.DeviceNotFound;
    }

    pub fn dropTrust(self: *DiosixClient) !void {
        const fd = try self.getFd();
        _ = try checkIoctlRc(linux.ioctl(fd, IOCTL_DROP_TRUST, 0));
    }

    pub fn getInfo(self: *DiosixClient, target_cid: usize) !GuestInfo {
        const fd = try self.getFd();
        var info: GuestInfo = undefined;
        @memset(std.mem.asBytes(&info), 0);
        info.guest_id = target_cid;
        _ = try checkIoctlRc(
            linux.ioctl(fd, IOCTL_GET_INFO, @intFromPtr(&info)),
        );
        return info;
    }

    pub fn run(
        self: *DiosixClient,
        child_id: usize,
        elf_data: []const u8,
        dtb_data: []const u8,
        arch: usize,
        flags: usize,
    ) !usize {
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
        const signed_rc = try checkIoctlRc(
            linux.ioctl(fd, IOCTL_RUN, @intFromPtr(&args)),
        );
        return if (args.child_id > 0)
            @intCast(args.child_id)
        else
            @intCast(signed_rc);
    }

    pub fn spawn(
        self: *DiosixClient,
        child_id: usize,
        elf_data: []const u8,
        dtb_data: []const u8,
        arch: usize,
        flags: usize,
    ) !usize {
        return self.run(child_id, elf_data, dtb_data, arch, flags);
    }

    pub fn terminate(
        self: *DiosixClient,
        target_id: usize,
        exit_code: usize,
    ) !void {
        const fd = try self.getFd();
        var args = TerminateArgs{
            .target_id = target_id,
            .exit_code = exit_code,
        };
        _ = try checkIoctlRc(
            linux.ioctl(fd, IOCTL_TERMINATE, @intFromPtr(&args)),
        );
    }

    pub fn exit(self: *DiosixClient, code: usize) void {
        _ = self.terminate(0, code) catch {};
    }

    pub fn waitEvent(
        self: *DiosixClient,
        target_cid: usize,
        nohang: bool,
    ) !?Event {
        const fd = try self.getFd();
        var args = WaitEventArgs{
            .target_cid = target_cid,
            .flags = if (nohang) 1 else 0,
            .event = std.mem.zeroes(Event),
        };
        const rc = linux.ioctl(fd, IOCTL_WAIT_EVENT, @intFromPtr(&args));
        const signed_rc: isize = @bitCast(rc);
        if (signed_rc == EPERM_NEG or signed_rc == EACCES_NEG) {
            return error.PermissionDenied;
        }
        // -EAGAIN on non-blocking check.
        if (signed_rc == EAGAIN_NEG) return null;
        if (signed_rc < 0) return error.HypercallFailed;
        return args.event;
    }

    pub fn setQuota(
        self: *DiosixClient,
        target_cid: usize,
        ram_pages: usize,
        vcpus: usize,
        depth: usize,
        descendants: usize,
    ) !void {
        return self.setQuotaWithPcpu(
            target_cid,
            ram_pages,
            vcpus,
            depth,
            descendants,
            0,
            0,
        );
    }

    pub fn setQuotaWithPcpu(
        self: *DiosixClient,
        target_cid: usize,
        ram_pages: usize,
        vcpus: usize,
        depth: usize,
        descendants: usize,
        pcpu_quota_pct: usize,
        logical_ram_pages: usize,
    ) !void {
        const fd = try self.getFd();
        var args = QuotaArgs{
            .target_cid = target_cid,
            .max_ram_pages = ram_pages,
            .max_vcpus = vcpus,
            .max_child_depth = depth,
            .max_descendants = descendants,
            .pcpu_quota_pct = pcpu_quota_pct,
            .logical_ram_pages = logical_ram_pages,
        };
        _ = try checkIoctlRc(
            linux.ioctl(fd, IOCTL_SET_QUOTA, @intFromPtr(&args)),
        );
    }

    pub fn getHypervisorInfo(self: *DiosixClient) !HypervisorInfo {
        const fd = try self.getFd();
        var info = std.mem.zeroes(HypervisorInfo);
        _ = try checkIoctlRc(
            linux.ioctl(fd, IOCTL_GET_HV_INFO, @intFromPtr(&info)),
        );
        return info;
    }

    pub fn getManifest(
        self: *DiosixClient,
        target_cid: usize,
        buffer: []u8,
    ) !usize {
        const fd = try self.getFd();
        var args = ManifestArgs{
            .target_cid = target_cid,
            .data_ptr = @intFromPtr(buffer.ptr),
            .max_len = buffer.len,
            .actual_len = 0,
        };
        _ = try checkIoctlRc(
            linux.ioctl(fd, IOCTL_GET_MANIFEST, @intFromPtr(&args)),
        );
        return @min(@as(usize, @intCast(args.actual_len)), buffer.len);
    }

    pub fn setManifest(
        self: *DiosixClient,
        target_cid: usize,
        data: []const u8,
    ) !void {
        const fd = try self.getFd();
        var args = ManifestArgs{
            .target_cid = target_cid,
            .data_ptr = @intFromPtr(data.ptr),
            .max_len = data.len,
            .actual_len = 0,
        };
        _ = try checkIoctlRc(
            linux.ioctl(fd, IOCTL_SET_MANIFEST, @intFromPtr(&args)),
        );
    }

    pub fn mapChildMemory(
        self: *DiosixClient,
        target_cid: usize,
        child_gpa: usize,
        parent_gpa: usize,
        size: usize,
        flags: usize,
    ) ![]u8 {
        const fd = try self.getFd();
        var args = MapChildMemArgs{
            .child_id = target_cid,
            .child_gpa = child_gpa,
            .parent_gpa = parent_gpa,
            .size = size,
            .flags = flags,
        };
        _ = try checkIoctlRc(
            linux.ioctl(fd, IOCTL_MAP_CHILD_MEM, @intFromPtr(&args)),
        );

        const mmap_res = linux.mmap(
            null,
            size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd,
            @intCast(args.parent_gpa),
        );
        const mmap_signed: isize = @bitCast(mmap_res);
        if (mmap_signed < 0) {
            var unmap_args = UnmapChildMemArgs{
                .parent_gpa = args.parent_gpa,
                .size = size,
            };
            _ = linux.ioctl(
                fd,
                IOCTL_UNMAP_CHILD_MEM,
                @intFromPtr(&unmap_args),
            );
            return error.OutOfMemory;
        }
        const ptr: [*]u8 = @ptrFromInt(mmap_res);
        return ptr[0..size];
    }

    pub fn unmapChildMemory(
        self: *DiosixClient,
        mapped_slice: []u8,
        parent_gpa: usize,
    ) !void {
        _ = linux.munmap(mapped_slice.ptr, mapped_slice.len);
        const fd = try self.getFd();
        var args = UnmapChildMemArgs{
            .parent_gpa = parent_gpa,
            .size = mapped_slice.len,
        };
        _ = try checkIoctlRc(
            linux.ioctl(fd, IOCTL_UNMAP_CHILD_MEM, @intFromPtr(&args)),
        );
    }

    pub fn startGuest(
        self: *DiosixClient,
        target_cid: usize,
        entry_point: usize,
        dtb_ptr: usize,
    ) !usize {
        const fd = try self.getFd();
        var args = StartArgs{
            .child_id = target_cid,
            .entry_point = entry_point,
            .dtb_ptr = dtb_ptr,
        };
        const signed_rc = try checkIoctlRc(
            linux.ioctl(fd, IOCTL_START, @intFromPtr(&args)),
        );
        return @intCast(signed_rc);
    }

    pub fn sealCharter(
        self: *DiosixClient,
        args: *const CharterArgs,
    ) !void {
        const fd = try self.getFd();
        _ = try checkIoctlRc(
            linux.ioctl(fd, IOCTL_SEAL_CHARTER, @intFromPtr(args)),
        );
    }

    pub fn getCharter(self: *DiosixClient) !CharterArgs {
        const fd = try self.getFd();
        var args = std.mem.zeroes(CharterArgs);
        _ = try checkIoctlRc(
            linux.ioctl(fd, IOCTL_GET_CHARTER, @intFromPtr(&args)),
        );
        return args;
    }

    pub fn ratifyCharter(
        self: *DiosixClient,
        target_cid: usize,
    ) !usize {
        const fd = try self.getFd();
        const signed_rc = try checkIoctlRc(
            linux.ioctl(fd, IOCTL_RATIFY_CHARTER, target_cid),
        );
        return @intCast(signed_rc);
    }

    pub fn resetSteward(
        self: *DiosixClient,
        target_cid: usize,
    ) !usize {
        const fd = try self.getFd();
        const signed_rc = try checkIoctlRc(
            linux.ioctl(fd, IOCTL_RESET_STEWARD, target_cid),
        );
        return @intCast(signed_rc);
    }

    pub fn requestRootFailover(
        self: *DiosixClient,
        standby_cid: usize,
    ) !usize {
        const fd = try self.getFd();
        const signed_rc = try checkIoctlRc(
            linux.ioctl(fd, IOCTL_REQUEST_ROOT_FAILOVER, standby_cid),
        );
        return @intCast(signed_rc);
    }

    pub fn consoleRead(
        self: *DiosixClient,
        target_cid: usize,
        buffer: []u8,
    ) !usize {
        const fd = try self.getFd();
        const req_len: usize = @min(buffer.len, MAX_CONSOLE_IO_BYTES);
        var args = ConsoleArgs{
            .target_cid = target_cid,
            .data_ptr = if (req_len > 0) @intFromPtr(buffer.ptr) else 0,
            .max_len = req_len,
            .actual_len = 0,
        };
        _ = try checkIoctlRc(
            linux.ioctl(fd, IOCTL_CONSOLE_READ, @intFromPtr(&args)),
        );
        return @min(@as(usize, @intCast(args.actual_len)), req_len);
    }

    pub fn consoleWrite(
        self: *DiosixClient,
        target_cid: usize,
        data: []const u8,
    ) !usize {
        if (data.len == 0) return 0;
        const fd = try self.getFd();
        const req_len: usize = @min(data.len, MAX_CONSOLE_IO_BYTES);
        var args = ConsoleArgs{
            .target_cid = target_cid,
            .data_ptr = @intFromPtr(data.ptr),
            .max_len = req_len,
            .actual_len = 0,
        };
        _ = try checkIoctlRc(
            linux.ioctl(fd, IOCTL_CONSOLE_WRITE, @intFromPtr(&args)),
        );
        return @min(@as(usize, @intCast(args.actual_len)), req_len);
    }
};

test "api: DiosixClient error mapping and checkIoctlRc" {
    std.testing.refAllDecls(@This());

    var missing_client = DiosixClient{ .dev_fd = null, .open_err = -2 };
    try std.testing.expectError(
        error.DeviceNotFound,
        missing_client.dropTrust(),
    );

    var denied_client = DiosixClient{
        .dev_fd = null,
        .open_err = EPERM_NEG,
    };
    try std.testing.expectError(
        error.PermissionDenied,
        denied_client.dropTrust(),
    );
}
