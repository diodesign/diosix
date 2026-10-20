// Real Host Telemetry & Hypervisor Information for Diosix GUI.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const sbi = @import("interface").sbi;
const label = @import("label.zig");
const mem_size = @import("host/mem.zig");
const time = @import("host/time.zig");
const paths = @import("paths.zig");

pub const fmtLabel = label.fmtLabel;
pub const LABEL_BUF_BYTES = label.LABEL_BUF_BYTES;
pub const MEM_SIZE_STR_BYTES = mem_size.MEM_SIZE_STR_BYTES;
pub const formatMemorySize = mem_size.formatMemorySize;

pub const SECS_PER_DAY = time.SECS_PER_DAY;
pub const SECS_PER_HOUR = time.SECS_PER_HOUR;
pub const SECS_PER_MIN = time.SECS_PER_MIN;
pub const HOURS_PER_DAY = time.HOURS_PER_DAY;
pub const MIN_VALID_EPOCH_SECS = time.MIN_VALID_EPOCH_SECS;
pub const DAYS_FROM_0000_TO_1970 = time.DAYS_FROM_0000_TO_1970;
pub const DAYS_PER_400Y_ERA = time.DAYS_PER_400Y_ERA;
pub const DAYS_PER_4Y_CYCLE = time.DAYS_PER_4Y_CYCLE;
pub const DAYS_PER_100Y_CENTURY = time.DAYS_PER_100Y_CENTURY;
pub const DAYS_PER_YEAR = time.DAYS_PER_YEAR;
pub const YEARS_PER_ERA = time.YEARS_PER_ERA;
pub const DAYS_PER_5M_CYCLE = time.DAYS_PER_5M_CYCLE;
pub const DateTimeUtc = time.DateTimeUtc;
pub const epochToUtc = time.epochToUtc;
pub const monthName = time.monthName;
pub const getHostDateTimeString = time.getHostDateTimeString;
pub const getHostUptimeSeconds = time.getHostUptimeSeconds;
pub const formatUptime = time.formatUptime;

// Hypervisor IOCTL definitions matching /dev/diosix driver and interface.
pub const IOCTL_BASE: u32 = 0x1000;
pub const IOCTL_TERMINATE: u32 = IOCTL_BASE + 6; // 0x1006.
pub const IOCTL_GET_HV_INFO: u32 = IOCTL_BASE + 11; // 0x100b.
pub const BUILD_COMMIT_LEN: usize = sbi.BUILD_COMMIT_LEN;
pub const HOST_CPU_ISA_LEN: usize = sbi.HOST_CPU_ISA_LEN;
pub const ISA_STR_LEN: usize = sbi.HOST_CPU_ISA_LEN;
pub const BUILD_DESC_LEN: usize = sbi.BUILD_DESC_LEN;
pub const DEFAULT_TIMER_FREQ_HZ: u32 = sbi.HOST_TIMER_FREQ_HZ;
pub const EXIT_CODE_POWEROFF: u64 = 0;
pub const EXIT_CODE_REBOOT: u64 = 1;

pub const HypervisorInfo = sbi.HypervisorInfo;
const TerminateArgs = sbi.TerminateArgs;

// Power Action definition.
pub const PowerAction = enum {
    restart,
    shutdown,
};

// Optional mock for testing environment where /dev/diosix is unavailable.
pub var mock_hypervisor_info: ?HypervisorInfo = null;
pub var mock_power_action: ?PowerAction = null;

// Execute hardware shutdown or reboot via hypervisor terminate ioctl and Linux.
pub fn executePowerAction(action: PowerAction) void {
    const builtin = @import("builtin");
    if (builtin.is_test or mock_power_action != null or
        mock_hypervisor_info != null)
    {
        mock_power_action = action;
        return;
    }

    // 1. Terminate Root VM via /dev/diosix hypervisor interface (CID_SELF = 1).
    const fd_rc = linux.open(paths.DEV_DIOSIX_PATH, .{ .ACCMODE = .RDWR }, 0);
    const signed_fd: isize = @bitCast(fd_rc);
    if (signed_fd >= 0) {
        const fd: i32 = @intCast(signed_fd);
        defer _ = linux.close(fd);
        var args = TerminateArgs{
            .target_id = sbi.CID_SELF,
            .exit_code = if (action == .restart)
                EXIT_CODE_REBOOT
            else
                EXIT_CODE_POWEROFF,
        };
        _ = linux.ioctl(fd, IOCTL_TERMINATE, @intFromPtr(&args));
    }

    // 2. Linux sys_reboot syscall.
    _ = linux.reboot(
        .MAGIC1,
        .MAGIC2,
        if (action == .restart) .RESTART else .POWER_OFF,
        null,
    );

    // 3. Exec fallback.
    const prog: [*:0]const u8 = if (action == .restart)
        paths.REBOOT_BIN_PATH
    else
        paths.POWEROFF_BIN_PATH;
    var argv = [_:null]?[*:0]const u8{ prog, null };
    _ = linux.execve(prog, &argv, &[_:null]?[*:0]const u8{null});
}

// Check if running as privileged root console on Root VM (/dev/diosix).
pub fn isRootConsole() bool {
    if (mock_hypervisor_info != null) return true;
    const fd_rc = linux.open(paths.DEV_DIOSIX_PATH, .{ .ACCMODE = .RDWR }, 0);
    const signed_fd: isize = @bitCast(fd_rc);
    if (signed_fd < 0) return false;
    _ = linux.close(@intCast(signed_fd));
    return true;
}

// Query the live hypervisor over /dev/diosix.
pub fn getHypervisorInfo() ?HypervisorInfo {
    if (mock_hypervisor_info) |mock| return mock;

    const fd_rc = linux.open(paths.DEV_DIOSIX_PATH, .{ .ACCMODE = .RDWR }, 0);
    const signed_fd: isize = @bitCast(fd_rc);
    if (signed_fd < 0) return null;

    const fd: i32 = @intCast(signed_fd);
    defer _ = linux.close(fd);

    var info = std.mem.zeroes(HypervisorInfo);
    const ioctl_rc = linux.ioctl(fd, IOCTL_GET_HV_INFO, @intFromPtr(&info));
    const signed_ioctl: isize = @bitCast(ioctl_rc);
    if (signed_ioctl < 0) return null;

    return info;
}

// Retrieve formatted version string: "diosix <version> <branch> <commit>".
pub fn getVersionString(buffer: []u8) []const u8 {
    if (getHypervisorInfo()) |info| {
        const commit_slice = std.mem.sliceTo(&info.build_commit, 0);
        const desc_slice = std.mem.sliceTo(&info.build_desc, 0);

        var branch_slice: []const u8 = "";
        if (desc_slice.len > 0) {
            var tok_it = std.mem.tokenizeScalar(u8, desc_slice, ' ');
            _ = tok_it.next(); // Skip "Version".
            _ = tok_it.next(); // Skip version number.
            var tok_opt = tok_it.next();
            if (tok_opt) |t| {
                if (t.len > 0 and t[0] == '(') tok_opt = tok_it.next();
            }
            if (tok_opt) |branch_commit| {
                if (std.mem.lastIndexOfScalar(u8, branch_commit, '/')) |slash| {
                    branch_slice = branch_commit[0..slash];
                }
            }
        }

        if (branch_slice.len > 0 and commit_slice.len > 0) {
            if (info.version_patch > 0) {
                return label.fmtLabel(buffer, "diosix {d}.{d}.{d} {s} {s}", .{
                    info.version_major,
                    info.version_minor,
                    info.version_patch,
                    branch_slice,
                    commit_slice,
                });
            }
            return label.fmtLabel(buffer, "diosix {d}.{d} {s} {s}", .{
                info.version_major,
                info.version_minor,
                branch_slice,
                commit_slice,
            });
        } else if (commit_slice.len > 0) {
            if (info.version_patch > 0) {
                return label.fmtLabel(buffer, "diosix {d}.{d}.{d} {s}", .{
                    info.version_major,
                    info.version_minor,
                    info.version_patch,
                    commit_slice,
                });
            }
            return label.fmtLabel(buffer, "diosix {d}.{d} {s}", .{
                info.version_major,
                info.version_minor,
                commit_slice,
            });
        }
    }
    return "diosix --";
}

// Format Host CPU cores and ISA value: "N x RV64..." or "--" on failure.
pub fn getHostCpuString(buffer: []u8) []const u8 {
    if (getHypervisorInfo()) |info| {
        if (info.host_physical_cores > 0) {
            const isa_slice = std.mem.sliceTo(&info.host_cpu_isa, 0);
            if (isa_slice.len > 0) {
                return label.fmtLabel(
                    buffer,
                    "{d} x {s}",
                    .{ info.host_physical_cores, isa_slice },
                );
            }
            return label.fmtLabel(
                buffer,
                "{d} physical cores",
                .{info.host_physical_cores},
            );
        }
    }
    return "--";
}

// Format Host RAM value: "X free of Y total (N% in use)" or "--" on failure.
// Never falls back to Root VM /proc/meminfo or hardcoded values.
pub fn getHostRamString(buffer: []u8) []const u8 {
    if (getHypervisorInfo()) |info| {
        const total_bytes = info.host_total_ram_kb *| mem_size.KIB;
        const free_bytes = info.host_free_ram_kb *| mem_size.KIB;
        if (total_bytes > 0 and free_bytes <= total_bytes) {
            var free_buf: [MEM_SIZE_STR_BYTES]u8 = undefined;
            const free_str = formatMemorySize(&free_buf, free_bytes);

            var total_buf: [MEM_SIZE_STR_BYTES]u8 = undefined;
            const total_str = formatMemorySize(&total_buf, total_bytes);

            const used_bytes = total_bytes - free_bytes;
            const pct: u64 = (used_bytes * 100) / total_bytes;

            return label.fmtLabel(
                buffer,
                "{s} free of {s} total ({d}% in use)",
                .{ free_str, total_str, pct },
            );
        }
    }
    return "--";
}

pub const HvBuildSplit = struct {
    line1: []const u8,
    line2: []const u8,
};

// Retrieve hypervisor build values:
// Line 1: "Version 26.1 (beta) guestdev/760a3d7 ..."
// Line 2: "(Zig 0.17.0-dev.648+8d1b6e339 riscv64)"
// Or "--" on failure.
pub fn getHvBuildSplit(buf1: []u8, buf2: []u8) HvBuildSplit {
    if (getHypervisorInfo()) |info| {
        const s = std.mem.sliceTo(&info.build_desc, 0);
        if (s.len > 0) {
            if (std.mem.lastIndexOfScalar(u8, s, '(')) |paren_idx| {
                const part1 = std.mem.trim(u8, s[0..paren_idx], " \t\r");
                const part2 = std.mem.trim(u8, s[paren_idx..], " \t\r");

                const l1 = label.fmtLabel(buf1, "{s}", .{part1});
                const l2 = label.fmtLabel(buf2, "{s}", .{part2});
                return .{ .line1 = l1, .line2 = l2 };
            } else {
                const l1 = label.fmtLabel(buf1, "{s}", .{s});
                return .{ .line1 = l1, .line2 = "" };
            }
        }
    }
    return .{ .line1 = "--", .line2 = "" };
}

// Retrieve hypervisor footprint value: "X free of Y reserved (Z% free)".
pub fn getHvFootprintString(buffer: []u8) []const u8 {
    if (getHypervisorInfo()) |info| {
        if (info.hv_reserved_bytes > 0) {
            const free_clamped =
                @min(info.hv_heap_free_bytes, info.hv_reserved_bytes);
            var free_buf: [MEM_SIZE_STR_BYTES]u8 = undefined;
            const free_str = formatMemorySize(&free_buf, free_clamped);

            var res_buf: [MEM_SIZE_STR_BYTES]u8 = undefined;
            const res_str = formatMemorySize(&res_buf, info.hv_reserved_bytes);

            const pct: u64 = (free_clamped * 100) / info.hv_reserved_bytes;

            return label.fmtLabel(
                buffer,
                "{s} free of {s} reserved ({d}% free)",
                .{ free_str, res_str, pct },
            );
        }
    }
    return "--";
}

test "HypervisorInfo ABI layout and version formatting in diosix-gui" {
    const testing = std.testing;
    testing.refAllDecls(@This());
    _ = .{ label, mem_size, time, paths };
    defer mock_hypervisor_info = null;

    try testing.expectEqual(@as(usize, 304), @sizeOf(HypervisorInfo));
    try testing.expectEqual(
        @as(usize, 10),
        @offsetOf(HypervisorInfo, "version_patch"),
    );

    var info = HypervisorInfo{
        .version_major = 26,
        .version_minor = 2,
        .version_patch = 1,
        .host_physical_cores = 4,
        .host_total_ram_kb = 2048 * 1024,
        .host_free_ram_kb = 1536 * 1024,
        .hv_reserved_bytes = 512 * 1024,
        .hv_heap_free_bytes = 256 * 1024,
    };
    @memcpy(info.build_commit[0..7], "a1b2c3d");
    @memcpy(info.host_cpu_isa[0..6], "RV64GC");
    const desc =
        "Version 26.2.1 (stable) main/a1b2c3d Oct 16 2026 chris@host " ++
        "(Zig 0.17.0 riscv64)";
    @memcpy(info.build_desc[0..desc.len], desc);

    mock_hypervisor_info = info;

    var buf: [LABEL_BUF_BYTES]u8 = undefined;
    try testing.expectEqualStrings(
        "diosix 26.2.1 main a1b2c3d",
        getVersionString(&buf),
    );
    try testing.expectEqualStrings("4 x RV64GC", getHostCpuString(&buf));
    try testing.expectEqualStrings(
        "1.5 GB free of 2 GB total (25% in use)",
        getHostRamString(&buf),
    );
    try testing.expectEqualStrings(
        "256 KB free of 512 KB reserved (50% free)",
        getHvFootprintString(&buf),
    );

    var b1: [LABEL_BUF_BYTES]u8 = undefined;
    var b2: [LABEL_BUF_BYTES]u8 = undefined;
    const split = getHvBuildSplit(&b1, &b2);
    try testing.expectEqualStrings(
        "Version 26.2.1 (stable) main/a1b2c3d Oct 16 2026 chris@host",
        split.line1,
    );
    try testing.expectEqualStrings("(Zig 0.17.0 riscv64)", split.line2);
}

test "host label getters truncate instead of showing a placeholder" {
    const testing = std.testing;
    defer mock_hypervisor_info = null;

    var info = std.mem.zeroes(HypervisorInfo);
    info.version_major = 26;
    info.version_minor = 2;
    info.host_physical_cores = 4;
    @memcpy(info.build_commit[0..7], "a1b2c3d");
    @memcpy(info.host_cpu_isa[0..6], "RV64GC");
    const desc = "Version 26.2 (stable) main/a1b2c3d (Zig 0.17.0)";
    @memcpy(info.build_desc[0..desc.len], desc);
    mock_hypervisor_info = info;

    var small: [6]u8 = undefined;
    try testing.expectEqualStrings("diosix", getVersionString(&small));
    try testing.expectEqualStrings("4 x RV", getHostCpuString(&small));

    var b1: [7]u8 = undefined;
    var b2: [4]u8 = undefined;
    const split = getHvBuildSplit(&b1, &b2);
    try testing.expectEqualStrings("Version", split.line1);
    try testing.expectEqualStrings("(Zig", split.line2);
}
