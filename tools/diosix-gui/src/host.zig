// Real Host Telemetry & Hypervisor Information for Diosix GUI.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const sbi = @import("interface").sbi;

// Hypervisor IOCTL definitions matching /dev/diosix driver and interface.
pub const IOCTL_BASE: u32 = 0x1000;
pub const IOCTL_TERMINATE: u32 = IOCTL_BASE + 6; // 0x1006.
pub const IOCTL_GET_HV_INFO: u32 = IOCTL_BASE + 11; // 0x100b.
pub const BUILD_COMMIT_LEN: usize = sbi.BUILD_COMMIT_LEN;
pub const HOST_CPU_ISA_LEN: usize = sbi.HOST_CPU_ISA_LEN;
pub const ISA_STR_LEN: usize = sbi.HOST_CPU_ISA_LEN;
pub const BUILD_DESC_LEN: usize = sbi.BUILD_DESC_LEN;
pub const DEFAULT_TIMER_FREQ_HZ: u32 = sbi.HOST_TIMER_FREQ_HZ;
pub const SECS_PER_DAY: u64 = 86_400;
pub const SECS_PER_HOUR: u64 = 3_600;
pub const SECS_PER_MIN: u64 = 60;
pub const HOURS_PER_DAY: u64 = 24;
pub const MIN_VALID_EPOCH_SECS: u64 = 1_704_067_200; // 2024-01-01T00:00:00Z.
pub const EXIT_CODE_POWEROFF: u64 = 0;
pub const EXIT_CODE_REBOOT: u64 = 1;

pub const DAYS_FROM_0000_TO_1970: u64 = 719_468;
pub const DAYS_PER_400Y_ERA: u64 = 146_097;
pub const DAYS_PER_4Y_CYCLE: u64 = 1_460;
pub const DAYS_PER_100Y_CENTURY: u64 = 36_524;
pub const DAYS_PER_YEAR: u64 = 365;
pub const YEARS_PER_ERA: u64 = 400;
pub const DAYS_PER_5M_CYCLE: u64 = 153;

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
    const fd_rc = linux.open("/dev/diosix", .{ .ACCMODE = .RDWR }, 0);
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
    const prog: [*:0]const u8 =
        if (action == .restart) "/sbin/reboot" else "/sbin/poweroff";
    var argv = [_:null]?[*:0]const u8{ prog, null };
    _ = linux.execve(prog, &argv, &[_:null]?[*:0]const u8{null});
}

// Check if running as privileged root console on Root VM (/dev/diosix).
pub fn isRootConsole() bool {
    if (mock_hypervisor_info != null) return true;
    const fd_rc = linux.open("/dev/diosix", .{ .ACCMODE = .RDWR }, 0);
    const signed_fd: isize = @bitCast(fd_rc);
    if (signed_fd < 0) return false;
    _ = linux.close(@intCast(signed_fd));
    return true;
}

// Query the live hypervisor over /dev/diosix.
pub fn getHypervisorInfo() ?HypervisorInfo {
    if (mock_hypervisor_info) |mock| return mock;

    const fd_rc = linux.open("/dev/diosix", .{ .ACCMODE = .RDWR }, 0);
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

// Format byte sizes into human-readable strings (bytes, KB, MB, GB).
pub fn formatMemorySize(buffer: []u8, bytes: u64) []const u8 {
    const GB: u64 = 1024 * 1024 * 1024;
    const MB: u64 = 1024 * 1024;
    const KB: u64 = 1024;

    if (bytes >= GB) {
        if (bytes % GB == 0) {
            return std.fmt.bufPrint(buffer, "{d} GB", .{bytes / GB}) catch "--";
        }
        const val =
            @as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(GB));
        return std.fmt.bufPrint(buffer, "{d:.1} GB", .{val}) catch "--";
    } else if (bytes >= MB) {
        if (bytes % MB == 0) {
            return std.fmt.bufPrint(buffer, "{d} MB", .{bytes / MB}) catch "--";
        }
        const val =
            @as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(MB));
        return std.fmt.bufPrint(buffer, "{d:.1} MB", .{val}) catch "--";
    } else if (bytes >= KB) {
        if (bytes % KB == 0) {
            return std.fmt.bufPrint(buffer, "{d} KB", .{bytes / KB}) catch "--";
        }
        const val =
            @as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(KB));
        return std.fmt.bufPrint(buffer, "{d:.1} KB", .{val}) catch "--";
    } else {
        return std.fmt.bufPrint(buffer, "{d} bytes", .{bytes}) catch "--";
    }
}

// Retrieve real host uptime in seconds, or null on failure.
pub fn getHostUptimeSeconds() ?u64 {
    // 1. Read live uptime from /proc/uptime.
    var buf: [64]u8 = undefined;
    const fd_rc = linux.open("/proc/uptime", .{ .ACCMODE = .RDONLY }, 0);
    const signed_fd: isize = @bitCast(fd_rc);
    if (signed_fd >= 0) {
        const fd: i32 = @intCast(signed_fd);
        defer _ = linux.close(fd);

        const read_rc = linux.read(fd, &buf, buf.len);
        const signed_read: isize = @bitCast(read_rc);
        if (signed_read > 0) {
            const content = buf[0..@intCast(signed_read)];
            var it = std.mem.splitScalar(u8, content, ' ');
            if (it.next()) |up_str| {
                var dot_it = std.mem.splitScalar(u8, up_str, '.');
                if (dot_it.next()) |secs_str| {
                    const trimmed = std.mem.trim(u8, secs_str, " \t\r\n");
                    if (std.fmt.parseInt(u64, trimmed, 10)) |secs| {
                        return secs;
                    } else |_| {}
                }
            }
        }
    }

    // 2. Fallback to clock_gettime(CLOCK_BOOTTIME).
    var ts: linux.timespec = undefined;
    const rc_boot = linux.clock_gettime(linux.CLOCK.BOOTTIME, &ts);
    if (rc_boot == 0 and ts.sec >= 0) {
        return @intCast(ts.sec);
    }

    // 3. Fallback to clock_gettime(CLOCK_MONOTONIC).
    const rc_mono = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);
    if (rc_mono == 0 and ts.sec >= 0) {
        return @intCast(ts.sec);
    }

    return null;
}

// Format uptime into human-readable text: "{d}d {d:0>2}h {d:0>2}m {d:0>2}s".
pub fn formatUptime(buffer: []u8) []const u8 {
    if (getHostUptimeSeconds()) |uptime_secs| {
        const days = uptime_secs / SECS_PER_DAY;
        const hours = (uptime_secs % SECS_PER_DAY) / SECS_PER_HOUR;
        const mins = (uptime_secs % SECS_PER_HOUR) / SECS_PER_MIN;
        const secs = uptime_secs % SECS_PER_MIN;

        return std.fmt.bufPrint(
            buffer,
            "{d}d {d:0>2}h {d:0>2}m {d:0>2}s",
            .{ days, hours, mins, secs },
        ) catch "--";
    }
    return "--";
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
                return std.fmt.bufPrint(buffer, "diosix {d}.{d}.{d} {s} {s}", .{
                    info.version_major,
                    info.version_minor,
                    info.version_patch,
                    branch_slice,
                    commit_slice,
                }) catch "diosix --";
            }
            return std.fmt.bufPrint(buffer, "diosix {d}.{d} {s} {s}", .{
                info.version_major,
                info.version_minor,
                branch_slice,
                commit_slice,
            }) catch "diosix --";
        } else if (commit_slice.len > 0) {
            if (info.version_patch > 0) {
                return std.fmt.bufPrint(buffer, "diosix {d}.{d}.{d} {s}", .{
                    info.version_major,
                    info.version_minor,
                    info.version_patch,
                    commit_slice,
                }) catch "diosix --";
            }
            return std.fmt.bufPrint(buffer, "diosix {d}.{d} {s}", .{
                info.version_major,
                info.version_minor,
                commit_slice,
            }) catch "diosix --";
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
                return std.fmt.bufPrint(
                    buffer,
                    "{d} x {s}",
                    .{ info.host_physical_cores, isa_slice },
                ) catch "--";
            }
            return std.fmt.bufPrint(
                buffer,
                "{d} physical cores",
                .{info.host_physical_cores},
            ) catch "--";
        }
    }
    return "--";
}

// Format Host RAM value: "X free of Y total (N% in use)" or "--" on failure.
// Never falls back to Root VM /proc/meminfo or hardcoded values.
pub fn getHostRamString(buffer: []u8) []const u8 {
    if (getHypervisorInfo()) |info| {
        const total_bytes = info.host_total_ram_kb *| 1024;
        const free_bytes = info.host_free_ram_kb *| 1024;
        if (total_bytes > 0 and free_bytes <= total_bytes) {
            var free_buf: [32]u8 = undefined;
            const free_str = formatMemorySize(&free_buf, free_bytes);

            var total_buf: [32]u8 = undefined;
            const total_str = formatMemorySize(&total_buf, total_bytes);

            const used_bytes = total_bytes - free_bytes;
            const pct: u64 = (used_bytes * 100) / total_bytes;

            return std.fmt.bufPrint(
                buffer,
                "{s} free of {s} total ({d}% in use)",
                .{ free_str, total_str, pct },
            ) catch "--";
        }
    }
    return "--";
}

// Gregorian UTC date-time struct.
pub const DateTimeUtc = struct {
    year: u32,
    month: u8, // 1..12.
    day: u8, // 1..31.
    hour: u8, // 0..23.
    minute: u8, // 0..59.
    second: u8, // 0..59.
};

// Convert Unix epoch timestamp to UTC Gregorian components.
pub fn epochToUtc(epoch_secs: u64) DateTimeUtc {
    var secs = epoch_secs;
    const sec: u8 = @intCast(secs % SECS_PER_MIN);
    secs /= SECS_PER_MIN;
    const min: u8 = @intCast(secs % SECS_PER_MIN);
    secs /= SECS_PER_MIN;
    const hour: u8 = @intCast(secs % HOURS_PER_DAY);
    var days: u64 = secs / HOURS_PER_DAY;

    days += DAYS_FROM_0000_TO_1970;
    const era: u64 = days / DAYS_PER_400Y_ERA;
    const doe: u64 = days - era * DAYS_PER_400Y_ERA;
    const yoe: u64 = (doe - doe / DAYS_PER_4Y_CYCLE +
        doe / DAYS_PER_100Y_CENTURY -
        doe / (DAYS_PER_400Y_ERA - 1)) / DAYS_PER_YEAR;
    const y: u64 = yoe + era * YEARS_PER_ERA;
    const doy: u64 = doe - (DAYS_PER_YEAR * yoe + yoe / 4 - yoe / 100);
    const mp: u64 = (5 * doy + 2) / DAYS_PER_5M_CYCLE;
    const d: u8 = @intCast(doy - (DAYS_PER_5M_CYCLE * mp + 2) / 5 + 1);
    const m: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    const final_y: u32 = @intCast(if (m <= 2) y + 1 else y);

    return .{
        .year = final_y,
        .month = m,
        .day = d,
        .hour = hour,
        .minute = min,
        .second = sec,
    };
}

const MONTH_NAMES = [12][]const u8{
    "January", "February", "March",     "April",   "May",      "June",
    "July",    "August",   "September", "October", "November", "December",
};

pub fn monthName(m: u8) []const u8 {
    if (m >= 1 and m <= 12) return MONTH_NAMES[m - 1];
    return "Unknown";
}

// Format Host time and date value: "HH:MM:SS UTC, Month Day, Year" or "--".
pub fn getHostDateTimeString(buffer: []u8) []const u8 {
    var ts: linux.timespec = undefined;
    const rc = linux.clock_gettime(linux.CLOCK.REALTIME, &ts);
    if (rc != 0 or ts.sec <= 0) return "--";

    const sec_epoch: u64 = @intCast(ts.sec);
    // Real-time clock before year 2024 is uninitialized/bogus.
    if (sec_epoch < MIN_VALID_EPOCH_SECS) return "--";

    const dt = epochToUtc(sec_epoch);
    const m_name = monthName(dt.month);
    return std.fmt.bufPrint(
        buffer,
        "{d:0>2}:{d:0>2}:{d:0>2} UTC, {s} {d}, {d}",
        .{ dt.hour, dt.minute, dt.second, m_name, dt.day, dt.year },
    ) catch "--";
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

                const l1 = std.fmt.bufPrint(buf1, "{s}", .{part1}) catch "--";
                const l2 = std.fmt.bufPrint(buf2, "{s}", .{part2}) catch "";
                return .{ .line1 = l1, .line2 = l2 };
            } else {
                const l1 = std.fmt.bufPrint(buf1, "{s}", .{s}) catch "--";
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
            var free_buf: [32]u8 = undefined;
            const free_str = formatMemorySize(&free_buf, free_clamped);

            var res_buf: [32]u8 = undefined;
            const res_str = formatMemorySize(&res_buf, info.hv_reserved_bytes);

            const pct: u64 = (free_clamped * 100) / info.hv_reserved_bytes;

            return std.fmt.bufPrint(
                buffer,
                "{s} free of {s} reserved ({d}% free)",
                .{ free_str, res_str, pct },
            ) catch "--";
        }
    }
    return "--";
}

test "HypervisorInfo ABI layout and version formatting in diosix-gui" {
    const testing = std.testing;
    testing.refAllDecls(@This());
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

    var buf: [128]u8 = undefined;
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

    var b1: [128]u8 = undefined;
    var b2: [128]u8 = undefined;
    const split = getHvBuildSplit(&b1, &b2);
    try testing.expectEqualStrings(
        "Version 26.2.1 (stable) main/a1b2c3d Oct 16 2026 chris@host",
        split.line1,
    );
    try testing.expectEqualStrings("(Zig 0.17.0 riscv64)", split.line2);
}
