// Diosix Guest Control API and ABI definitions
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;

pub const EXT_DIOSIX: usize = 0x0A000005;

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
    target_arch: u8, // 0 = rv64, 1 = rv32, 2 = aarch64, 3 = x86_64
    _reserved: u8 = 0,
    used_ram_pages: usize,
    max_ram_pages: usize,
    used_vcpus: usize,
    max_vcpus: usize,
    child_count: usize,
};

pub const SpawnArgs = extern struct {
    child_id: usize,
    elf_ptr: usize,
    elf_size: usize,
    dtb_ptr: usize,
    dtb_size: usize,
    target_arch: usize,
};

pub const QuotaArgs = extern struct {
    child_id: usize,
    max_ram_pages: usize,
    max_vcpus: usize,
    max_priority: usize,
};

// IOCTL command definitions for /dev/diosix
pub const IOCTL_FORK = 0x1001;
pub const IOCTL_DROP_TRUST = 0x1002;
pub const IOCTL_SPAWN = 0x1003;
pub const IOCTL_GET_INFO = 0x1004;
pub const IOCTL_SET_QUOTA = 0x1005;
pub const IOCTL_TERMINATE = 0x1006;
pub const IOCTL_EXIT = 0x1006;
pub const IOCTL_KILL = 0x1006;
pub const IOCTL_YIELD = 0x1007;


pub const DiosixClient = struct {
    dev_fd: ?i32,

    pub fn init() DiosixClient {
        const path = "/dev/diosix";
        const rc = linux.open(path, .{ .ACCMODE = .RDWR }, 0);
        const signed_rc: isize = @bitCast(rc);
        if (signed_rc >= 0) {
            return .{ .dev_fd = @intCast(signed_rc) };
        }
        return .{ .dev_fd = null };
    }

    pub fn deinit(self: *DiosixClient) void {
        if (self.dev_fd) |fd| {
            _ = linux.close(fd);
            self.dev_fd = null;
        }
    }

    /// Perform a hypercall via /dev/diosix ioctl
    pub fn fork(self: *DiosixClient) !usize {
        const fd = self.dev_fd orelse return error.DeviceNotFound;
        var child_id: usize = 0;
        const rc = linux.ioctl(fd, IOCTL_FORK, @intFromPtr(&child_id));
        if (@as(isize, @bitCast(rc)) < 0) return error.HypercallFailed;
        return child_id;
    }

    pub fn dropTrust(self: *DiosixClient) !void {
        const fd = self.dev_fd orelse return error.DeviceNotFound;
        const rc = linux.ioctl(fd, IOCTL_DROP_TRUST, 0);
        if (@as(isize, @bitCast(rc)) < 0) return error.HypercallFailed;
    }

    pub fn getInfo(self: *DiosixClient) !GuestInfo {
        const fd = self.dev_fd orelse return error.DeviceNotFound;
        var info: GuestInfo = undefined;
        const rc = linux.ioctl(fd, IOCTL_GET_INFO, @intFromPtr(&info));
        if (@as(isize, @bitCast(rc)) < 0) return error.HypercallFailed;
        return info;
    }

    pub fn spawn(self: *DiosixClient, child_id: usize, elf_data: []const u8, dtb_data: []const u8, arch: usize) !void {
        const fd = self.dev_fd orelse return error.DeviceNotFound;
        var args = SpawnArgs{
            .child_id = child_id,
            .elf_ptr = @intFromPtr(elf_data.ptr),
            .elf_size = elf_data.len,
            .dtb_ptr = if (dtb_data.len > 0) @intFromPtr(dtb_data.ptr) else 0,
            .dtb_size = dtb_data.len,
            .target_arch = arch,
        };
        const rc = linux.ioctl(fd, IOCTL_SPAWN, @intFromPtr(&args));
        if (@as(isize, @bitCast(rc)) < 0) return error.HypercallFailed;
    }

    pub fn terminate(self: *DiosixClient, target_id: usize) !void {
        const fd = self.dev_fd orelse return error.DeviceNotFound;
        const rc = linux.ioctl(fd, IOCTL_TERMINATE, target_id);
        if (@as(isize, @bitCast(rc)) < 0) return error.HypercallFailed;
    }

    pub fn exit(self: *DiosixClient, code: usize) void {
        _ = self.terminate(code) catch {};
    }


};

fn sbiCall(ext: usize, func: usize, a0: usize, a1: usize, a2: usize) SbiResult {
    var err: isize = undefined;
    var val: usize = undefined;

    switch (@import("builtin").cpu.arch) {
        .riscv64, .riscv32 => {
            asm volatile (
                \\ecall
                : [err] "={x10}" (err),
                  [val] "={x11}" (val),
                : [a0] "{x10}" (a0),
                  [a1] "{x11}" (a1),
                  [a2] "{x12}" (a2),
                  [func] "{x16}" (func),
                  [ext] "{x17}" (ext),
            );
        },
        else => {
            err = -1;
            val = 0;
        },
    }

    return .{ .err = err, .value = val };
}
