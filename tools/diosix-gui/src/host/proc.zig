// Linux /proc and /run/diosix/guests.toml Telemetry Helpers for Diosix GUI.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const paths = @import("../paths.zig");
const label = @import("../label.zig");
const mem_size = @import("mem.zig");

pub const MAX_FILE_READ_BYTES: usize = 16384;
pub const MAX_TRACKED_CIDS: usize = 128;
pub const STORAGE_LABEL_BYTES: usize = 64;
pub const MAX_GUEST_STORAGE: usize = 6;
pub const GUEST_NAME_BYTES: usize = 48;
pub const PCPU_HISTORY_LEN: usize = 60;

pub const RegistryEntry = struct {
    cid: u64 = 0,
    name: []const u8 = "",
    image: []const u8 = "",
    vcpus: u32 = 1,
    ram: []const u8 = "",
    disk: []const u8 = "",
    cdrom: []const u8 = "",
    status: []const u8 = "running",

    pub fn applyKeyVal(
        self: *RegistryEntry,
        key: []const u8,
        val: []const u8,
    ) void {
        if (std.mem.eql(u8, key, "cid")) {
            self.cid = std.fmt.parseInt(u64, val, 10) catch 0;
        } else if (std.mem.eql(u8, key, "name")) {
            self.name = val;
        } else if (std.mem.eql(u8, key, "image")) {
            self.image = val;
        } else if (std.mem.eql(u8, key, "vcpus")) {
            self.vcpus = std.fmt.parseInt(u32, val, 10) catch 1;
        } else if (std.mem.eql(u8, key, "ram")) {
            self.ram = val;
        } else if (std.mem.eql(u8, key, "disk")) {
            self.disk = val;
        } else if (std.mem.eql(u8, key, "cdrom")) {
            self.cdrom = val;
        } else if (std.mem.eql(u8, key, "status")) {
            self.status = val;
        }
    }
};

pub fn trimTomlValue(raw: []const u8) []const u8 {
    return std.mem.trim(u8, raw, " \t\r\n\"");
}

pub fn basenameSlice(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| {
        if (slash + 1 < path.len) return path[slash + 1 ..];
    }
    return path;
}

pub fn friendlyImageName(raw_path: []const u8) []const u8 {
    const base = basenameSlice(raw_path);
    if (std.mem.eql(u8, base, "diosix-base-linux.elf") or
        std.mem.eql(u8, base, "diosix-base-linux") or
        std.mem.eql(u8, base, "base-linux") or
        std.mem.eql(u8, base, "diosix-linux.elf") or
        std.mem.eql(u8, base, "diosix-linux") or
        std.mem.eql(u8, base, "default.elf") or
        std.mem.eql(u8, base, "default"))
    {
        return "Diosix Base Linux";
    }
    return base;
}

const MIN_SAMPLE_INTERVAL_NS: u64 = 50_000_000;
const NS_PER_KHZ_TICK: u64 = 100_000;
const NS_PER_SEC: i128 = 1_000_000_000;

const CpuSample = struct {
    has_sample: bool = false,
    prev_khz_ticks: u32 = 0,
    prev_ns: i128 = 0,
    last_pct: u32 = 0,
    history: [PCPU_HISTORY_LEN]u8 = @splat(0),
    history_len: u8 = 0,
};

var hv_cpu_samples: [MAX_TRACKED_CIDS]CpuSample = @splat(.{});
var prev_proc_total: u64 = 0;
var prev_proc_idle: u64 = 0;
var last_proc_pct: u32 = 0;

pub fn resetCpuSamples() void {
    hv_cpu_samples = @splat(.{});
    prev_proc_total = 0;
    prev_proc_idle = 0;
    last_proc_pct = 0;
}

fn getSampleSlotIndex(cid: u64) usize {
    if (cid < MAX_TRACKED_CIDS) return @intCast(cid);
    return @intCast(32 + (cid % (MAX_TRACKED_CIDS - 32)));
}

pub fn resetGuestCpuSample(cid: u64) void {
    hv_cpu_samples[getSampleSlotIndex(cid)] = .{};
}

pub fn readSmallFile(path: [*:0]const u8, buf: []u8) []const u8 {
    const fd_rc = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    const signed_fd: isize = @bitCast(fd_rc);
    if (signed_fd < 0) return "";
    const fd: i32 = @intCast(signed_fd);
    defer _ = linux.close(fd);

    var total: usize = 0;
    while (total < buf.len) {
        const rd_rc = linux.read(fd, buf[total..].ptr, buf.len - total);
        const signed_rd: isize = @bitCast(rd_rc);
        if (signed_rd <= 0) break;
        total += @intCast(signed_rd);
    }
    return buf[0..total];
}

fn monotonicNowNs() i128 {
    var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
    const rc = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);
    const signed_rc: isize = @bitCast(rc);
    if (signed_rc < 0) return 0;
    return @as(i128, ts.sec) * NS_PER_SEC + @as(i128, ts.nsec);
}

pub fn computeHvCpuPercent(cid: u64, khz_ticks: u32, vcpus: u32) u32 {
    const slot = getSampleSlotIndex(cid);
    const now_ns = monotonicNowNs();
    var sample = &hv_cpu_samples[slot];
    if (!sample.has_sample or now_ns <= sample.prev_ns) {
        sample.has_sample = true;
        sample.prev_khz_ticks = khz_ticks;
        sample.prev_ns = now_ns;
        return sample.last_pct;
    }

    const dt_ns: u64 = @intCast(now_ns - sample.prev_ns);
    if (dt_ns < MIN_SAMPLE_INTERVAL_NS) return sample.last_pct;

    const delta_ticks: u64 = if (khz_ticks >= sample.prev_khz_ticks)
        khz_ticks - sample.prev_khz_ticks
    else if (sample.prev_khz_ticks - khz_ticks < 0x8000_0000)
        khz_ticks
    else
        khz_ticks -% sample.prev_khz_ticks;
    sample.prev_khz_ticks = khz_ticks;
    sample.prev_ns = now_ns;

    const active_ns: u64 = delta_ticks *| NS_PER_KHZ_TICK;
    const core_count: u64 = @max(@as(u64, 1), @as(u64, vcpus));
    const capacity_ns: u64 = dt_ns *| core_count;
    if (capacity_ns == 0) return sample.last_pct;

    const pct: u64 = @min(
        @as(u64, 100),
        (active_ns *| 100 + capacity_ns / 2) / capacity_ns,
    );
    sample.last_pct = @intCast(pct);
    return sample.last_pct;
}

pub fn pushPcpuHistorySample(cid: u64, pct: u32) void {
    const slot = getSampleSlotIndex(cid);
    var sample = &hv_cpu_samples[slot];
    const clamped: u8 = @intCast(@min(@as(u32, 100), pct));
    if (sample.history_len < PCPU_HISTORY_LEN) {
        sample.history[sample.history_len] = clamped;
        sample.history_len += 1;
    } else {
        std.mem.copyForwards(
            u8,
            sample.history[0 .. PCPU_HISTORY_LEN - 1],
            sample.history[1..PCPU_HISTORY_LEN],
        );
        sample.history[PCPU_HISTORY_LEN - 1] = clamped;
    }
}

pub fn copyPcpuHistory(cid: u64, out: *[PCPU_HISTORY_LEN]u8) u8 {
    const slot = getSampleSlotIndex(cid);
    const sample = &hv_cpu_samples[slot];
    const len: usize = @min(@as(usize, sample.history_len), PCPU_HISTORY_LEN);
    @memcpy(out[0..len], sample.history[0..len]);
    if (len < PCPU_HISTORY_LEN) {
        @memset(out[len..PCPU_HISTORY_LEN], 0);
    }
    return @intCast(len);
}

pub fn sampleRootProcCpuPercent() u32 {
    var buf: [2048]u8 = undefined;
    const content = readSmallFile(paths.PROC_STAT_PATH, &buf);
    if (content.len == 0) return last_proc_pct;

    var line_it = std.mem.tokenizeAny(u8, content, "\r\n");
    const first_line = line_it.next() orelse return last_proc_pct;
    if (!std.mem.startsWith(u8, first_line, "cpu ")) return last_proc_pct;

    var tok_it = std.mem.tokenizeAny(u8, first_line[4..], " \t");
    var total: u64 = 0;
    var idle: u64 = 0;
    var idx: usize = 0;
    while (tok_it.next()) |tok| : (idx += 1) {
        const val = std.fmt.parseInt(u64, tok, 10) catch 0;
        total +|= val;
        if (idx == 3 or idx == 4) idle +|= val;
    }

    if (prev_proc_total > 0 and total > prev_proc_total) {
        const d_total = total - prev_proc_total;
        const d_idle = if (idle >= prev_proc_idle) idle - prev_proc_idle else 0;
        const d_busy = if (d_total >= d_idle) d_total - d_idle else 0;
        last_proc_pct = @intCast(@min(@as(u64, 100), (d_busy * 100) / d_total));
    }
    prev_proc_total = total;
    prev_proc_idle = idle;
    return last_proc_pct;
}

pub fn queryRootMemTotalBytes() ?u64 {
    var buf: [2048]u8 = undefined;
    const content = readSmallFile(paths.PROC_MEMINFO_PATH, &buf);
    if (content.len == 0) return null;

    var line_it = std.mem.tokenizeAny(u8, content, "\r\n");
    while (line_it.next()) |line| {
        if (std.mem.startsWith(u8, line, "MemTotal:")) {
            var tok_it = std.mem.tokenizeAny(
                u8,
                line["MemTotal:".len..],
                " \t",
            );
            if (tok_it.next()) |kb_str| {
                const kb = std.fmt.parseInt(u64, kb_str, 10) catch return null;
                if (kb > 0) return kb * mem_size.KIB;
            }
        }
    }
    return null;
}

pub fn parseRamStringBytes(ram_str: []const u8) u64 {
    const trimmed = std.mem.trim(u8, ram_str, " \t\r\n\"");
    if (trimmed.len == 0) return 0;

    var end_digits: usize = 0;
    while (end_digits < trimmed.len and
        trimmed[end_digits] >= '0' and trimmed[end_digits] <= '9')
    {
        end_digits += 1;
    }
    if (end_digits == 0) return 0;
    const num = std.fmt.parseInt(
        u64,
        trimmed[0..end_digits],
        10,
    ) catch return 0;
    const unit = std.mem.trim(u8, trimmed[end_digits..], " \t");
    if (unit.len > 0 and (unit[0] == 'G' or unit[0] == 'g')) {
        return num * mem_size.GIB;
    }
    if (unit.len > 0 and (unit[0] == 'K' or unit[0] == 'k')) {
        return num * mem_size.KIB;
    }
    return num * mem_size.MIB;
}

pub fn collectRootStorage(
    out_bufs: *[MAX_GUEST_STORAGE][STORAGE_LABEL_BYTES]u8,
    out_lens: *[MAX_GUEST_STORAGE]usize,
) usize {
    var count: usize = 0;
    var mounts_buf: [4096]u8 = undefined;
    const mounts = readSmallFile(paths.PROC_MOUNTS_PATH, &mounts_buf);
    var has_root_mount = false;

    if (mounts.len > 0) {
        var line_it = std.mem.tokenizeAny(u8, mounts, "\r\n");
        while (line_it.next()) |line| {
            if (count >= MAX_GUEST_STORAGE) break;
            var tok_it = std.mem.tokenizeAny(u8, line, " \t");
            const dev = tok_it.next() orelse continue;
            const mnt = tok_it.next() orelse continue;
            const fstype = tok_it.next() orelse "";

            if (std.mem.startsWith(u8, dev, paths.DEV_DIR_PREFIX) and
                !std.mem.startsWith(u8, dev, paths.DEV_PTS_PREFIX) and
                !std.mem.startsWith(u8, dev, paths.DEV_SHM_PREFIX) and
                !std.mem.startsWith(u8, dev, paths.DEV_LOOP_PREFIX))
            {
                if (std.mem.eql(u8, mnt, "/")) has_root_mount = true;
                const s = label.fmtLabel(&out_bufs[count], "{s} ({s})", .{
                    dev,
                    mnt,
                });
                out_lens[count] = s.len;
                count += 1;
            } else if (std.mem.eql(u8, mnt, "/") and
                (std.mem.eql(u8, fstype, "rootfs") or
                    std.mem.eql(u8, fstype, "tmpfs")))
            {
                has_root_mount = true;
            }
        }
    }

    var parts_buf: [2048]u8 = undefined;
    const parts = readSmallFile(paths.PROC_PARTITIONS_PATH, &parts_buf);
    if (parts.len > 0 and count < MAX_GUEST_STORAGE) {
        var line_it = std.mem.tokenizeAny(u8, parts, "\r\n");
        while (line_it.next()) |line| {
            if (count >= MAX_GUEST_STORAGE) break;
            var tok_it = std.mem.tokenizeAny(u8, line, " \t");
            _ = tok_it.next() orelse continue;
            _ = tok_it.next() orelse continue;
            const blocks_s = tok_it.next() orelse continue;
            const name = tok_it.next() orelse continue;
            const blocks = std.fmt.parseInt(u64, blocks_s, 10) catch continue;
            if (blocks == 0 or std.mem.startsWith(u8, name, "ram") or
                std.mem.startsWith(u8, name, "loop"))
            {
                continue;
            }

            var dev_buf: [48]u8 = undefined;
            const dev_path = label.fmtLabel(
                &dev_buf,
                paths.DEV_NODE_FMT,
                .{name},
            );
            var already_listed = false;
            for (0..count) |i| {
                const existing = out_bufs[i][0..out_lens[i]];
                if (std.mem.startsWith(u8, existing, dev_path)) {
                    already_listed = true;
                    break;
                }
            }
            if (!already_listed) {
                var sz_buf: [mem_size.MEM_SIZE_STR_BYTES]u8 = undefined;
                const sz_str = mem_size.formatMemorySize(
                    &sz_buf,
                    blocks * mem_size.KIB,
                );
                const s = label.fmtLabel(&out_bufs[count], "{s} ({s})", .{
                    dev_path,
                    sz_str,
                });
                out_lens[count] = s.len;
                count += 1;
            }
        }
    }

    if (count == 0 and has_root_mount) {
        const s = label.fmtLabel(&out_bufs[0], "initramfs (/)", .{});
        out_lens[0] = s.len;
        count = 1;
    }
    return count;
}

pub fn invokeDsxSubcommand(subcmd: [*:0]const u8, cid: u64) bool {
    var cid_buf: [24]u8 = @splat(0);
    const cid_slice = std.fmt.bufPrint(
        cid_buf[0 .. cid_buf.len - 1],
        "{d}",
        .{cid},
    ) catch return false;
    cid_buf[cid_slice.len] = 0;
    const cid_arg: [*:0]const u8 = @ptrCast(&cid_buf);

    for (paths.DSX_BIN_PATHS) |dsx_bin| {
        const st_fd = linux.open(dsx_bin, .{ .ACCMODE = .RDONLY }, 0);
        const st_signed: isize = @bitCast(st_fd);
        if (st_signed < 0) continue;
        _ = linux.close(@intCast(st_signed));

        const pid_rc = linux.fork();
        const signed_pid: isize = @bitCast(pid_rc);
        if (signed_pid < 0) return false;
        if (signed_pid == 0) {
            var argv = [_:null]?[*:0]const u8{ dsx_bin, subcmd, cid_arg, null };
            var envp = [_:null]?[*:0]const u8{null};
            _ = linux.execve(dsx_bin, &argv, &envp);
            linux.exit(127);
        }
        var status: u32 = 0;
        _ = linux.waitpid(@intCast(signed_pid), @ptrCast(&status), 0);
        return (status & 0xff00) == 0;
    }
    return false;
}

test "proc: parseRamStringBytes and computeHvCpuPercent" {
    std.testing.refAllDecls(@This());
    resetCpuSamples();
    try std.testing.expectEqual(
        @as(u64, 256 * mem_size.MIB),
        parseRamStringBytes("256 MB"),
    );
    try std.testing.expectEqual(
        @as(u64, 2 * mem_size.GIB),
        parseRamStringBytes("2 GB"),
    );
    try std.testing.expectEqual(
        @as(u64, 512 * mem_size.KIB),
        parseRamStringBytes("512 KB"),
    );
}
