// Host Uptime & UTC Gregorian Date-Time Formatting for Diosix GUI.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const label = @import("../label.zig");
const mem_size = @import("mem.zig");
const paths = @import("../paths.zig");

pub const SECS_PER_DAY: u64 = 86_400;
pub const SECS_PER_HOUR: u64 = 3_600;
pub const SECS_PER_MIN: u64 = 60;
pub const HOURS_PER_DAY: u64 = 24;
pub const MIN_VALID_EPOCH_SECS: u64 = 1_704_067_200; // 2024-01-01T00:00:00Z.

pub const DAYS_FROM_0000_TO_1970: u64 = 719_468;
pub const DAYS_PER_400Y_ERA: u64 = 146_097;
pub const DAYS_PER_4Y_CYCLE: u64 = 1_460;
pub const DAYS_PER_100Y_CENTURY: u64 = 36_524;
pub const DAYS_PER_YEAR: u64 = 365;
pub const YEARS_PER_ERA: u64 = 400;
pub const DAYS_PER_5M_CYCLE: u64 = 153;

// /proc/uptime is "<uptime>.<cc> <idle>.<cc>\n": two decimal floats, each at
// most a u64's digits plus ".cc", separated by a space and ended by a newline.
// Only the first float is parsed, and it always lies within this size.
const PROC_UPTIME_BYTES: usize = 2 * (mem_size.U64_MAX_DIGITS + ".00".len) +
    " \n".len;

// Retrieve real host uptime in seconds, or null on failure.
pub fn getHostUptimeSeconds() ?u64 {
    // 1. Read live uptime from /proc/uptime.
    var buf: [PROC_UPTIME_BYTES]u8 = undefined;
    const uptime_path = paths.PROC_UPTIME_PATH;
    const fd_rc = linux.open(uptime_path, .{ .ACCMODE = .RDONLY }, 0);
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

        return label.fmtLabel(
            buffer,
            "{d}d {d:0>2}h {d:0>2}m {d:0>2}s",
            .{ days, hours, mins, secs },
        );
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
    return label.fmtLabel(
        buffer,
        "{d:0>2}:{d:0>2}:{d:0>2} UTC, {s} {d}, {d}",
        .{ dt.hour, dt.minute, dt.second, m_name, dt.day, dt.year },
    );
}

test "time: epochToUtc and monthName conversions" {
    std.testing.refAllDecls(@This());
    const dt = epochToUtc(MIN_VALID_EPOCH_SECS);
    try std.testing.expectEqual(@as(u32, 2024), dt.year);
    try std.testing.expectEqual(@as(u8, 1), dt.month);
    try std.testing.expectEqual(@as(u8, 1), dt.day);
    try std.testing.expectEqualStrings("January", monthName(dt.month));
    try std.testing.expectEqualStrings("Unknown", monthName(0));
}
