// Live Running Guest VM Discovery, Telemetry & Lifecycle Control for Diosix.
//
// Queries /dev/diosix (IOCTL_GET_INFO, IOCTL_TERMINATE, IOCTL_START),
// /run/diosix/guests.toml, and /proc to provide real-time guest VM metrics,
// attached storage inventory, and restart/shutdown operations.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const sbi = @import("interface").sbi;
const label = @import("../label.zig");
const paths = @import("../paths.zig");
const mem_size = @import("mem.zig");
const proc = @import("proc.zig");

pub const MAX_RUNNING_GUESTS: usize = 32;
pub const MAX_GUEST_STORAGE: usize = proc.MAX_GUEST_STORAGE;
pub const STORAGE_LABEL_BYTES: usize = proc.STORAGE_LABEL_BYTES;
pub const GUEST_NAME_BYTES: usize = proc.GUEST_NAME_BYTES;
pub const PCPU_HISTORY_LEN: usize = proc.PCPU_HISTORY_LEN;

pub const IOCTL_BASE: u32 = 0x1000;
pub const IOCTL_GET_INFO: u32 = IOCTL_BASE + 4; // 0x1004.
pub const IOCTL_SET_QUOTA: u32 = IOCTL_BASE + 5; // 0x1005.
pub const IOCTL_TERMINATE: u32 = IOCTL_BASE + 6; // 0x1006.
pub const IOCTL_GET_HV_INFO: u32 = IOCTL_BASE + 11; // 0x100b.
pub const IOCTL_START: u32 = IOCTL_BASE + 16; // 0x1010.

const PAGE_SIZE_BYTES: u64 = 4096;
const DEFAULT_ROOT_RAM_BYTES: u64 = 256 * mem_size.MIB;
const DEFAULT_ROOT_QUOTA_BYTES: u64 = 1536 * mem_size.MIB;
const DEFAULT_ROOT_VCPUS: u32 = 4;

pub const GuestActionKind = enum {
    restart,
    shutdown,
    set_quota,
};

pub const GuestActionRecord = struct {
    cid: u64,
    action: GuestActionKind,
    pcpu_quota_pct: u32 = 0,
    ram_quota_mb: u32 = 0,
};

pub const RunningGuest = struct {
    cid: u64 = 0,
    is_root: bool = false,
    target_arch: u8 = @backingInt(sbi.TargetArch.riscv64),
    is_h_mode: bool = true,
    instance_name: [GUEST_NAME_BYTES]u8 = @splat(0),
    instance_len: usize = 0,
    image_name: [GUEST_NAME_BYTES]u8 = @splat(0),
    image_len: usize = 0,
    vcpus: u32 = 1,
    pcpu_percent: u32 = 0,
    pcpu_quota_pct: u32 = sbi.DEFAULT_CHILD_PCPU_QUOTA_PCT,
    delegated_pcpu_pct: u32 = 0,
    pcpu_history: [PCPU_HISTORY_LEN]u8 = @splat(0),
    pcpu_history_len: u8 = 0,
    ram_bytes: u64 = 0,
    ram_quota_bytes: u64 = 0,
    delegated_ram_bytes: u64 = 0,
    used_ram_bytes: u64 = 0,
    storage_items: [MAX_GUEST_STORAGE][STORAGE_LABEL_BYTES]u8 =
        @splat(@splat(0)),
    storage_lens: [MAX_GUEST_STORAGE]usize = @splat(0),
    storage_count: usize = 0,

    pub fn getArchLabel(self: *const RunningGuest) []const u8 {
        return switch (self.target_arch) {
            @backingInt(sbi.TargetArch.riscv32) => "RV32",
            @backingInt(sbi.TargetArch.aarch64) => "Aarch64",
            @backingInt(sbi.TargetArch.x86_64) => "x86_64",
            else => "RV64",
        };
    }

    pub fn getVirtModeLabel(self: *const RunningGuest) []const u8 {
        const rv64 = @backingInt(sbi.TargetArch.riscv64);
        return if (self.is_h_mode and self.target_arch == rv64)
            "H-mode"
        else
            "PMP";
    }

    pub fn getPcpuHistory(self: *const RunningGuest) []const u8 {
        const len: usize = @min(self.pcpu_history_len, PCPU_HISTORY_LEN);
        return self.pcpu_history[0..len];
    }

    pub fn getInstanceName(self: *const RunningGuest) []const u8 {
        return self.instance_name[0..self.instance_len];
    }

    pub fn getImageName(self: *const RunningGuest) []const u8 {
        return self.image_name[0..self.image_len];
    }

    pub fn getStorageItem(self: *const RunningGuest, idx: usize) []const u8 {
        if (idx >= self.storage_count) return "";
        return self.storage_items[idx][0..self.storage_lens[idx]];
    }

    pub fn setInstanceName(self: *RunningGuest, name: []const u8) void {
        const s = label.fmtLabel(&self.instance_name, "{s}", .{name});
        self.instance_len = s.len;
    }
    pub fn setImageName(self: *RunningGuest, name: []const u8) void {
        const s = label.fmtLabel(&self.image_name, "{s}", .{name});
        self.image_len = s.len;
    }
    pub fn addStorageItem(self: *RunningGuest, item: []const u8) void {
        if (item.len == 0 or self.storage_count >= MAX_GUEST_STORAGE) return;
        const idx = self.storage_count;
        const s = label.fmtLabel(&self.storage_items[idx], "{s}", .{item});
        self.storage_lens[idx] = s.len;
        self.storage_count += 1;
    }
};

pub var mock_running_guests: ?[]const RunningGuest = null;
pub var mock_last_guest_action: ?GuestActionRecord = null;

var cached_guests: [MAX_RUNNING_GUESTS]RunningGuest = undefined;
var cached_guests_count: usize = 0;
var has_cached_guests: bool = false;

pub fn resetGuestTelemetryCache() void {
    has_cached_guests = false;
    cached_guests_count = 0;
    proc.resetCpuSamples();
}

fn queryGuestInfoIoctl(fd: i32, target_cid: u64) ?sbi.GuestInfo {
    var info = std.mem.zeroes(sbi.GuestInfo);
    info.guest_id = target_cid;
    const rc = linux.ioctl(fd, IOCTL_GET_INFO, @intFromPtr(&info));
    const signed_rc: isize = @bitCast(rc);
    if (signed_rc < 0) return null;
    return info;
}

fn queryHvCaps(fd: i32, pcpus_out: *u32, hw_virt_out: *bool) void {
    var hv = std.mem.zeroes(sbi.HypervisorInfo);
    const rc = linux.ioctl(fd, IOCTL_GET_HV_INFO, @intFromPtr(&hv));
    if (@as(isize, @bitCast(rc)) >= 0) {
        if (hv.host_physical_cores > 0) pcpus_out.* = hv.host_physical_cores;
        const hw_bit = sbi.HypervisorFeature.HARDWARE_VIRT;
        hw_virt_out.* = (hv.features & hw_bit) != 0;
    }
}

fn applyGuestInfo(
    g: *RunningGuest,
    info: sbi.GuestInfo,
    host_pcpus: u32,
    hw_virt: bool,
) void {
    g.target_arch = info.target_arch;
    g.is_h_mode = hw_virt and
        (info.target_arch == @backingInt(sbi.TargetArch.riscv64));
    if (info.vcpus > 0) g.vcpus = @intCast(info.vcpus);
    if (info.self_ram_pages > 0) {
        g.ram_bytes = info.self_ram_pages * PAGE_SIZE_BYTES;
    }
    if (info.pcpu_quota_pct > 0) g.pcpu_quota_pct = info.pcpu_quota_pct;
    g.delegated_pcpu_pct = info.delegated_pcpu_pct;
    if (info.max_ram_pages > 0 and
        info.max_ram_pages < std.math.maxInt(u64) / PAGE_SIZE_BYTES)
    {
        g.ram_quota_bytes = info.max_ram_pages * PAGE_SIZE_BYTES;
    }
    g.delegated_ram_bytes = info.delegated_ram_pages *| PAGE_SIZE_BYTES;
    g.used_ram_bytes = info.used_ram_pages *| PAGE_SIZE_BYTES;
    const denom = @max(host_pcpus, g.vcpus);
    g.pcpu_percent = proc.computeHvCpuPercent(g.cid, info.cpu_khz_ticks, denom);
}

fn flushRegistryEntry(
    entry: proc.RegistryEntry,
    dev_fd: ?i32,
    host_pcpus: u32,
    hw_virt: bool,
    out: *[MAX_RUNNING_GUESTS]RunningGuest,
    count: *usize,
) void {
    if (entry.cid < sbi.CID_FIRST_CHILD or count.* >= MAX_RUNNING_GUESTS) {
        return;
    }
    if (entry.status.len > 0 and !std.mem.eql(u8, entry.status, "running")) {
        return;
    }
    for (0..count.*) |i| if (out[i].cid == entry.cid) return;

    var g = RunningGuest{
        .cid = entry.cid,
        .is_root = false,
        .is_h_mode = hw_virt,
        .vcpus = @max(@as(u32, 1), entry.vcpus),
        .ram_bytes = proc.parseRamStringBytes(entry.ram),
    };
    if (dev_fd) |fd| {
        const info = queryGuestInfoIoctl(fd, entry.cid) orelse return;
        applyGuestInfo(&g, info, host_pcpus, hw_virt);
    }
    if (g.ram_bytes == 0) g.ram_bytes = DEFAULT_ROOT_RAM_BYTES;
    if (g.ram_quota_bytes == 0) g.ram_quota_bytes = g.ram_bytes;

    if (entry.name.len > 0 and !std.mem.eql(u8, entry.name, entry.image)) {
        g.setInstanceName(entry.name);
    } else {
        var name_buf: [GUEST_NAME_BYTES]u8 = undefined;
        g.setInstanceName(label.fmtLabel(&name_buf, "guest-{d}", .{entry.cid}));
    }
    if (entry.image.len > 0) {
        g.setImageName(proc.friendlyImageName(entry.image));
    } else if (entry.cdrom.len > 0) {
        g.setImageName(proc.friendlyImageName(entry.cdrom));
    } else if (entry.disk.len > 0) {
        g.setImageName("guest-shim");
    } else {
        g.setImageName("Diosix Base Linux");
    }
    var sbuf: [STORAGE_LABEL_BYTES]u8 = undefined;
    if (entry.disk.len > 0) {
        g.addStorageItem(label.fmtLabel(&sbuf, "disk: {s}", .{entry.disk}));
    }
    if (entry.cdrom.len > 0) {
        g.addStorageItem(label.fmtLabel(&sbuf, "cdrom: {s}", .{entry.cdrom}));
    }
    out[count.*] = g;
    count.* += 1;
}

fn parseRegistryGuests(
    content: []const u8,
    dev_fd: ?i32,
    host_pcpus: u32,
    hw_virt: bool,
    out: *[MAX_RUNNING_GUESTS]RunningGuest,
    count: *usize,
) void {
    var current = proc.RegistryEntry{};
    var in_guest = false;
    var line_it = std.mem.tokenizeAny(u8, content, "\r\n");
    while (line_it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.eql(u8, line, "[[guest]]")) {
            if (in_guest) {
                const f = dev_fd;
                flushRegistryEntry(current, f, host_pcpus, hw_virt, out, count);
            }
            current = .{};
            in_guest = true;
            continue;
        }
        if (!in_guest) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        current.applyKeyVal(key, proc.trimTomlValue(line[eq + 1 ..]));
    }
    if (in_guest) {
        flushRegistryEntry(current, dev_fd, host_pcpus, hw_virt, out, count);
    }
}

fn finalizeSampledGuests(
    out: *[MAX_RUNNING_GUESTS]RunningGuest,
    count: usize,
) usize {
    for (0..count) |i| {
        if (out[i].pcpu_history_len == 0) {
            proc.pushPcpuHistorySample(out[i].cid, out[i].pcpu_percent);
            out[i].pcpu_history_len =
                proc.copyPcpuHistory(out[i].cid, &out[i].pcpu_history);
        }
        cached_guests[i] = out[i];
    }
    cached_guests_count = count;
    has_cached_guests = true;
    return count;
}

pub fn sampleRunningGuests(out: *[MAX_RUNNING_GUESTS]RunningGuest) usize {
    if (mock_running_guests) |mocks| {
        const n: usize = @min(mocks.len, MAX_RUNNING_GUESTS);
        for (0..n) |i| out[i] = mocks[i];
        return finalizeSampledGuests(out, n);
    }

    if (builtin.is_test) {
        var root_vm = RunningGuest{
            .cid = sbi.CID_SELF,
            .is_root = true,
            .vcpus = DEFAULT_ROOT_VCPUS,
            .pcpu_quota_pct = 100,
            .ram_bytes = DEFAULT_ROOT_RAM_BYTES,
            .ram_quota_bytes = DEFAULT_ROOT_QUOTA_BYTES,
        };
        root_vm.setInstanceName("root");
        root_vm.setImageName("rootvm");
        root_vm.addStorageItem("initramfs (/)");
        out[0] = root_vm;
        return finalizeSampledGuests(out, 1);
    }
    const fd_rc = linux.open(paths.DEV_DIOSIX_PATH, .{ .ACCMODE = .RDWR }, 0);
    const signed_fd: isize = @bitCast(fd_rc);
    const dev_fd: ?i32 = if (signed_fd >= 0) @intCast(signed_fd) else null;
    defer if (dev_fd) |fd| {
        _ = linux.close(fd);
    };
    var count: usize = 0;
    const root_ram = proc.queryRootMemTotalBytes() orelse
        DEFAULT_ROOT_RAM_BYTES;
    var root_vm = RunningGuest{
        .cid = sbi.CID_SELF,
        .is_root = true,
        .vcpus = DEFAULT_ROOT_VCPUS,
        .pcpu_quota_pct = 100,
        .ram_bytes = root_ram,
        .ram_quota_bytes = DEFAULT_ROOT_QUOTA_BYTES,
    };
    root_vm.setInstanceName("root");
    root_vm.setImageName("rootvm");
    var host_pcpus: u32 = DEFAULT_ROOT_VCPUS;
    var hw_virt: bool = true;
    var expected_children: usize = 0;
    if (dev_fd) |fd| {
        queryHvCaps(fd, &host_pcpus, &hw_virt);
        root_vm.is_h_mode = hw_virt;
        if (queryGuestInfoIoctl(fd, sbi.CID_SELF)) |info| {
            applyGuestInfo(&root_vm, info, host_pcpus, hw_virt);
            expected_children = @intCast(info.child_count);
        } else root_vm.pcpu_percent = proc.sampleRootProcCpuPercent();
    } else root_vm.pcpu_percent = proc.sampleRootProcCpuPercent();
    root_vm.storage_count = proc.collectRootStorage(
        &root_vm.storage_items,
        &root_vm.storage_lens,
    );
    out[0] = root_vm;
    count = 1;

    var reg_buf: [proc.MAX_FILE_READ_BYTES]u8 = undefined;
    const reg = proc.readSmallFile(paths.GUEST_REGISTRY_PATH, &reg_buf);
    if (reg.len > 0) {
        parseRegistryGuests(reg, dev_fd, host_pcpus, hw_virt, out, &count);
    }

    if (dev_fd) |fd| {
        var cid: u64 = sbi.CID_FIRST_CHILD;
        while (count - 1 < expected_children and
            count < MAX_RUNNING_GUESTS and
            cid < sbi.CID_FIRST_CHILD + MAX_RUNNING_GUESTS) : (cid += 1)
        {
            var present = false;
            for (1..count) |i| if (out[i].cid == cid) {
                present = true;
                break;
            };
            if (present) continue;
            if (queryGuestInfoIoctl(fd, cid)) |cinfo| {
                var cg = RunningGuest{
                    .cid = cid,
                    .is_root = false,
                    .vcpus = 1,
                    .ram_bytes = DEFAULT_ROOT_RAM_BYTES,
                };
                applyGuestInfo(&cg, cinfo, host_pcpus, hw_virt);
                if (cg.ram_quota_bytes == 0) cg.ram_quota_bytes = cg.ram_bytes;
                var nbuf: [GUEST_NAME_BYTES]u8 = undefined;
                cg.setInstanceName(label.fmtLabel(&nbuf, "guest-{d}", .{cid}));
                cg.setImageName("Diosix Base Linux");
                out[count] = cg;
                count += 1;
            }
        }
    }
    return finalizeSampledGuests(out, count);
}

pub fn queryRunningGuests(out: *[MAX_RUNNING_GUESTS]RunningGuest) usize {
    if (!has_cached_guests) return sampleRunningGuests(out);
    for (0..cached_guests_count) |i| out[i] = cached_guests[i];
    return cached_guests_count;
}

fn invokeDevIoctl(cmd: u32, arg_ptr: usize) bool {
    const fd_rc = linux.open(paths.DEV_DIOSIX_PATH, .{ .ACCMODE = .RDWR }, 0);
    const signed_fd: isize = @bitCast(fd_rc);
    if (signed_fd < 0) return false;
    const fd: i32 = @intCast(signed_fd);
    defer _ = linux.close(fd);
    const rc = linux.ioctl(fd, cmd, arg_ptr);
    return @as(isize, @bitCast(rc)) >= 0;
}

pub fn restartGuestVm(cid: u64) bool {
    if (cid < sbi.CID_FIRST_CHILD) return false;
    if (builtin.is_test or mock_running_guests != null) {
        mock_last_guest_action = .{ .cid = cid, .action = .restart };
        return true;
    }
    if (proc.invokeDsxSubcommand("restart", cid)) return true;
    var sargs = sbi.StartArgs{
        .child_id = cid,
        .entry_point = 0,
        .dtb_ptr = 0,
    };
    return invokeDevIoctl(IOCTL_START, @intFromPtr(&sargs));
}

pub fn shutdownGuestVm(cid: u64) bool {
    if (cid < sbi.CID_FIRST_CHILD) return false;
    if (builtin.is_test or mock_running_guests != null) {
        mock_last_guest_action = .{ .cid = cid, .action = .shutdown };
        return true;
    }
    if (proc.invokeDsxSubcommand("stop", cid)) return true;
    var targs = sbi.TerminateArgs{ .target_id = cid, .exit_code = 0 };
    return invokeDevIoctl(IOCTL_TERMINATE, @intFromPtr(&targs));
}

pub fn setGuestQuota(cid: u64, pcpu_pct: u32, ram_quota_mb: u32) bool {
    if (cid < sbi.CID_FIRST_CHILD) return false;
    if (builtin.is_test or mock_running_guests != null) {
        mock_last_guest_action = .{
            .cid = cid,
            .action = .set_quota,
            .pcpu_quota_pct = pcpu_pct,
            .ram_quota_mb = ram_quota_mb,
        };
        for (0..cached_guests_count) |i| {
            if (cached_guests[i].cid == cid) {
                if (pcpu_pct > 0) cached_guests[i].pcpu_quota_pct = pcpu_pct;
                if (ram_quota_mb > 0) {
                    cached_guests[i].ram_quota_bytes =
                        @as(u64, ram_quota_mb) * mem_size.MIB;
                }
            }
        }
        return true;
    }
    var qargs = sbi.QuotaArgs{
        .target_cid = cid,
        .max_ram_pages = (@as(u64, ram_quota_mb) * 1024) / 4,
        .pcpu_quota_pct = pcpu_pct,
    };
    return invokeDevIoctl(IOCTL_SET_QUOTA, @intFromPtr(&qargs));
}

test "guests: parseRegistryGuests and lifecycle protections" {
    std.testing.refAllDecls(@This());
    defer mock_running_guests = null;
    defer mock_last_guest_action = null;

    const sample_toml =
        \\[[guest]]
        \\cid = 2
        \\name = "worker-alpha"
        \\image = "diosix-linux.elf"
        \\vcpus = 2
        \\ram = "512 MB"
        \\disk = "/var/lib/diosix/disks/worker-alpha.raw"
        \\cdrom = "/var/lib/diosix/isos/debian.iso"
        \\status = "running"
    ;

    var list: [MAX_RUNNING_GUESTS]RunningGuest = undefined;
    var count: usize = 0;
    parseRegistryGuests(sample_toml, null, 4, true, &list, &count);
    const expectEq = std.testing.expectEqual;
    const expectStr = std.testing.expectEqualStrings;
    try expectEq(@as(usize, 1), count);
    try expectEq(@as(u64, 2), list[0].cid);
    try expectStr("worker-alpha", list[0].getInstanceName());
    try expectStr("Diosix Base Linux", list[0].getImageName());
    try expectStr("RV64", list[0].getArchLabel());
    try expectStr("H-mode", list[0].getVirtModeLabel());
    try expectEq(@as(u32, 2), list[0].vcpus);
    try expectEq(@as(u64, 512 * mem_size.MIB), list[0].ram_bytes);
    try expectEq(@as(usize, 2), list[0].storage_count);
    try std.testing.expect(!restartGuestVm(1));
    try std.testing.expect(!shutdownGuestVm(1));
    try std.testing.expect(!setGuestQuota(1, 50, 512));
    try std.testing.expect(restartGuestVm(2));
    try expectEq(@as(u64, 2), mock_last_guest_action.?.cid);
    try expectEq(GuestActionKind.restart, mock_last_guest_action.?.action);
    try std.testing.expect(setGuestQuota(2, 50, 1024));
    try expectEq(@as(u32, 50), mock_last_guest_action.?.pcpu_quota_pct);
    try expectEq(@as(u32, 1024), mock_last_guest_action.?.ram_quota_mb);
}
