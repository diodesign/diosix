// Real Host Telemetry & Hypervisor Information for Diosix GUI
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;

// Hypervisor IOCTL definitions matching /dev/diosix driver and hypervisor interface
pub const IOCTL_BASE: u32 = 0x1000;
pub const IOCTL_GET_HV_INFO: u32 = IOCTL_BASE + 11; // 0x100B
pub const BUILD_COMMIT_LEN: usize = 16;

pub const HypervisorInfo = extern struct {
    abi_version_major: u16 = 0,
    abi_version_minor: u16 = 2,
    abi_version_patch: u16 = 0,
    version_major: u16 = 26,
    version_minor: u16 = 1,
    _reserved0: u16 = 0,
    _reserved1: u32 = 0,
    build_commit: [BUILD_COMMIT_LEN]u8 = std.mem.zeroes([BUILD_COMMIT_LEN]u8),
    features: u64 = 0,
    host_physical_cores: u32 = 0,
    host_timer_freq_hz: u32 = 10_000_000,
    host_total_ram_kb: u64 = 0,
    host_free_ram_kb: u64 = 0,
    hv_reserved_bytes: u64 = 0,
    hv_heap_free_bytes: u64 = 0,
    host_cpu_isa: [32]u8 = std.mem.zeroes([32]u8),
    build_desc: [192]u8 = std.mem.zeroes([192]u8),
};

// Optional mock for testing environment where /dev/diosix is unavailable
pub var mock_hypervisor_info: ?HypervisorInfo = null;

// Query the live hypervisor over /dev/diosix
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

// Format byte sizes into human-readable strings (bytes, KB, MB, GB)
pub fn formatMemorySize(buffer: []u8, bytes: u64) []const u8 {
    const GB: u64 = 1024 * 1024 * 1024;
    const MB: u64 = 1024 * 1024;
    const KB: u64 = 1024;

    if (bytes >= GB) {
        if (bytes % GB == 0) {
            return std.fmt.bufPrint(buffer, "{d} GB", .{bytes / GB}) catch "--";
        }
        const val = @as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(GB));
        return std.fmt.bufPrint(buffer, "{d:.1} GB", .{val}) catch "--";
    } else if (bytes >= MB) {
        if (bytes % MB == 0) {
            return std.fmt.bufPrint(buffer, "{d} MB", .{bytes / MB}) catch "--";
        }
        const val = @as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(MB));
        return std.fmt.bufPrint(buffer, "{d:.1} MB", .{val}) catch "--";
    } else if (bytes >= KB) {
        if (bytes % KB == 0) {
            return std.fmt.bufPrint(buffer, "{d} KB", .{bytes / KB}) catch "--";
        }
        const val = @as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(KB));
        return std.fmt.bufPrint(buffer, "{d:.1} KB", .{val}) catch "--";
    } else {
        return std.fmt.bufPrint(buffer, "{d} bytes", .{bytes}) catch "--";
    }
}

// Retrieve real host uptime in seconds, or null on failure
pub fn getHostUptimeSeconds() ?u64 {
    // 1. Read live uptime from /proc/uptime
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
                    if (std.fmt.parseInt(u64, std.mem.trim(u8, secs_str, " \t\r\n"), 10)) |secs| {
                        return secs;
                    } else |_| {}
                }
            }
        }
    }

    // 2. Fallback to clock_gettime(CLOCK_BOOTTIME)
    var ts: linux.timespec = undefined;
    const rc_boot = linux.clock_gettime(linux.CLOCK.BOOTTIME, &ts);
    if (rc_boot == 0 and ts.sec >= 0) {
        return @intCast(ts.sec);
    }

    // 3. Fallback to clock_gettime(CLOCK_MONOTONIC)
    const rc_mono = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);
    if (rc_mono == 0 and ts.sec >= 0) {
        return @intCast(ts.sec);
    }

    return null;
}

// Format uptime value into human-readable text: "{d}d {d:0>2}h {d:0>2}m {d:0>2}s" or "--"
pub fn formatUptime(buffer: []u8) []const u8 {
    if (getHostUptimeSeconds()) |uptime_secs| {
        const days = uptime_secs / 86400;
        const hours = (uptime_secs % 86400) / 3600;
        const mins = (uptime_secs % 3600) / 60;
        const secs = uptime_secs % 60;

        return std.fmt.bufPrint(buffer, "{d}d {d:0>2}h {d:0>2}m {d:0>2}s", .{ days, hours, mins, secs }) catch "--";
    }
    return "--";
}

// Retrieve formatted version string: "diosix <version> <branch> <commit>" or "diosix --" on failure
pub fn getVersionString(buffer: []u8) []const u8 {
    if (getHypervisorInfo()) |info| {
        const commit_slice = std.mem.sliceTo(&info.build_commit, 0);
        const desc_slice = std.mem.sliceTo(&info.build_desc, 0);

        var branch_slice: []const u8 = "";
        if (desc_slice.len > 0) {
            var tok_it = std.mem.tokenizeScalar(u8, desc_slice, ' ');
            _ = tok_it.next(); // skip "Version"
            _ = tok_it.next(); // skip version number
            if (tok_it.next()) |branch_commit| {
                if (std.mem.indexOfScalar(u8, branch_commit, '/')) |slash| {
                    branch_slice = branch_commit[0..slash];
                }
            }
        }

        if (branch_slice.len > 0 and commit_slice.len > 0) {
            return std.fmt.bufPrint(buffer, "diosix {d}.{d} {s} {s}", .{
                info.version_major,
                info.version_minor,
                branch_slice,
                commit_slice,
            }) catch "diosix --";
        } else if (commit_slice.len > 0) {
            return std.fmt.bufPrint(buffer, "diosix {d}.{d} {s}", .{
                info.version_major,
                info.version_minor,
                commit_slice,
            }) catch "diosix --";
        }
    }
    return "diosix --";
}

// Format Host CPU cores and ISA value: "N x RV64..." or "--" on failure
pub fn getHostCpuString(buffer: []u8) []const u8 {
    if (getHypervisorInfo()) |info| {
        if (info.host_physical_cores > 0) {
            const isa_slice = std.mem.sliceTo(&info.host_cpu_isa, 0);
            if (isa_slice.len > 0) {
                return std.fmt.bufPrint(buffer, "{d} x {s}", .{ info.host_physical_cores, isa_slice }) catch "--";
            } else {
                return std.fmt.bufPrint(buffer, "{d} physical cores", .{ info.host_physical_cores }) catch "--";
            }
        }
    }
    return "--";
}

// Format Host RAM value: "X free of Y total (N% in use)" or "--" on failure
// Never falls back to Root VM /proc/meminfo or hardcoded values
pub fn getHostRamString(buffer: []u8) []const u8 {
    if (getHypervisorInfo()) |info| {
        const total_bytes = info.host_total_ram_kb * 1024;
        const free_bytes = info.host_free_ram_kb * 1024;
        if (total_bytes > 0 and free_bytes <= total_bytes) {
            var free_buf: [32]u8 = undefined;
            const free_str = formatMemorySize(&free_buf, free_bytes);

            var total_buf: [32]u8 = undefined;
            const total_str = formatMemorySize(&total_buf, total_bytes);

            const used_bytes = total_bytes - free_bytes;
            const pct: u64 = (used_bytes * 100) / total_bytes;

            return std.fmt.bufPrint(buffer, "{s} free of {s} total ({d}% in use)", .{ free_str, total_str, pct }) catch "--";
        }
    }
    return "--";
}

fn parseMeminfoKb(line: []const u8) u64 {
    if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
        const rest = std.mem.trim(u8, line[colon + 1 ..], " \t\r");
        var num_len: usize = 0;
        while (num_len < rest.len and std.ascii.isDigit(rest[num_len])) : (num_len += 1) {}
        if (num_len > 0) {
            return std.fmt.parseInt(u64, rest[0..num_len], 10) catch 0;
        }
    }
    return 0;
}

// Gregorian UTC date-time struct
pub const DateTimeUtc = struct {
    year: u32,
    month: u8, // 1..12
    day: u8, // 1..31
    hour: u8, // 0..23
    minute: u8, // 0..59
    second: u8, // 0..59
};

// Convert Unix epoch timestamp to UTC Gregorian components
pub fn epochToUtc(epoch_secs: u64) DateTimeUtc {
    var secs = epoch_secs;
    const sec: u8 = @intCast(secs % 60);
    secs /= 60;
    const min: u8 = @intCast(secs % 60);
    secs /= 60;
    const hour: u8 = @intCast(secs % 24);
    var days: u64 = secs / 24;

    days += 719468;
    const era: u64 = days / 146097;
    const doe: u64 = days - era * 146097;
    const yoe: u64 = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const y: u64 = yoe + era * 400;
    const doy: u64 = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp: u64 = (5 * doy + 2) / 153;
    const d: u8 = @intCast(doy - (153 * mp + 2) / 5 + 1);
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

pub fn monthName(m: u8) []const u8 {
    return switch (m) {
        1 => "January",
        2 => "February",
        3 => "March",
        4 => "April",
        5 => "May",
        6 => "June",
        7 => "July",
        8 => "August",
        9 => "September",
        10 => "October",
        11 => "November",
        12 => "December",
        else => "Unknown",
    };
}

// Format Host time and date value: "HH:MM:SS UTC, Month Day, Year" or "--" on failure
pub fn getHostDateTimeString(buffer: []u8) []const u8 {
    var ts: linux.timespec = undefined;
    const rc = linux.clock_gettime(linux.CLOCK.REALTIME, &ts);
    if (rc != 0 or ts.sec <= 0) {
        return "--";
    }

    const sec_epoch: u64 = @intCast(ts.sec);
    // Real-time clock before year 2024 is uninitialized/bogus
    if (sec_epoch < 1704067200) {
        return "--";
    }

    const dt = epochToUtc(sec_epoch);
    return std.fmt.bufPrint(buffer, "{d:0>2}:{d:0>2}:{d:0>2} UTC, {s} {d}, {d}", .{
        dt.hour,
        dt.minute,
        dt.second,
        monthName(dt.month),
        dt.day,
        dt.year,
    }) catch "--";
}

pub const HvBuildSplit = struct {
    line1: []const u8,
    line2: []const u8,
};

// Retrieve hypervisor build values:
// Line 1: "Version 26.1 guestdev/760a3d7 Wed Sep 16 12:48:32 AM PDT 2026 chris@violet"
// Line 2: "(Zig 0.17.0-dev.648+8d1b6e339 riscv64)"
// Or "--" on failure
pub fn getHvBuildSplit(buf1: []u8, buf2: []u8) HvBuildSplit {
    if (getHypervisorInfo()) |info| {
        const s = std.mem.sliceTo(&info.build_desc, 0);
        if (s.len > 0) {
            if (std.mem.indexOfScalar(u8, s, '(')) |paren_idx| {
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

// Retrieve hypervisor footprint value: "X free of Y reserved (Z% free)" or "--" on failure
pub fn getHvFootprintString(buffer: []u8) []const u8 {
    if (getHypervisorInfo()) |info| {
        if (info.hv_reserved_bytes > 0) {
            var free_buf: [32]u8 = undefined;
            const free_str = formatMemorySize(&free_buf, info.hv_heap_free_bytes);

            var res_buf: [32]u8 = undefined;
            const res_str = formatMemorySize(&res_buf, info.hv_reserved_bytes);

            const pct: u64 = (info.hv_heap_free_bytes * 100) / info.hv_reserved_bytes;

            return std.fmt.bufPrint(buffer, "{s} free of {s} reserved ({d}% free)", .{ free_str, res_str, pct }) catch "--";
        }
    }
    return "--";
}
