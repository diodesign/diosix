// Diosix Personal Desktop Runtime Launch, Stop, & Active State Tracking.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const api = @import("../api.zig");
const common = @import("../common.zig");
const sysconfig = @import("../sysconfig.zig");
const vm = @import("../vm.zig");
const vm_owned = @import("../vm/owned.zig");
const vm_passthrough = @import("../vm/passthrough.zig");
const config = @import("config.zig");

pub const MAX_CONFIG_BYTES: usize = 64 * 1024;
const STOP_POLL_ITERS: usize = 100;
const STOP_POLL_NS: isize = 20_000_000;

pub const ActiveDesktop = struct {
    cid: usize,
    profile_buf: [64]u8 = @splat(0),
    profile_len: usize = 0,

    pub fn profile(self: *const ActiveDesktop) []const u8 {
        return self.profile_buf[0..self.profile_len];
    }
};

pub fn makeParentDir(path: []const u8) void {
    const dir = if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx|
        path[0..idx]
    else
        return;
    var z_buf: [common.MAX_PATH_LEN]u8 = undefined;
    if (common.toPathZ(dir, &z_buf)) |z| {
        _ = linux.mkdir(z.ptr, 0o755);
    }
}

pub fn loadEffectiveConfig(allocator: std.mem.Allocator) !config.PersonalConfig {
    const cands = [_][]const u8{
        sysconfig.PERSONAL_STATE_CONFIG_PATH,
        sysconfig.PERSONAL_CONFIG_PATH,
    };
    for (cands) |path| {
        if (common.readBinaryFile(path, MAX_CONFIG_BYTES)) |bytes| {
            defer common.unmapBinaryFile(bytes);
            return config.parsePersonalConfig(allocator, bytes);
        } else |_| {}
    }
    return config.PersonalConfig.init(allocator);
}

pub fn saveEffectiveConfig(
    allocator: std.mem.Allocator,
    cfg: *const config.PersonalConfig,
) !void {
    const toml = try config.serializePersonalConfig(allocator, cfg);
    defer allocator.free(toml);

    makeParentDir(sysconfig.PERSONAL_CONFIG_PATH);
    try common.writeFile(sysconfig.PERSONAL_CONFIG_PATH, toml);

    var state_z: [common.MAX_PATH_LEN]u8 = undefined;
    if (common.toPathZ(sysconfig.VAR_LIB_DIOSIX_DIR, &state_z)) |sz| {
        if (common.fileExistsPath(sz.ptr)) {
            makeParentDir(sysconfig.PERSONAL_STATE_CONFIG_PATH);
            common.writeFile(sysconfig.PERSONAL_STATE_CONFIG_PATH, toml) catch {};
        }
    }
}

pub fn readActiveDesktop(client: *api.DiosixClient) ?ActiveDesktop {
    const bytes = common.readBinaryFile(sysconfig.PERSONAL_CID_PATH, 256) catch
        return null;
    defer common.unmapBinaryFile(bytes);
    const trimmed = common.trimWhitespace(bytes);
    if (trimmed.len == 0) return null;

    var it = std.mem.splitScalar(u8, trimmed, ':');
    const cid_s = it.next() orelse return null;
    const pname = it.next() orelse "desktop";
    const cid = common.parseCid(cid_s) catch return null;

    _ = client.getInfo(cid) catch {
        removeActiveDesktopFile();
        return null;
    };

    var out = ActiveDesktop{ .cid = cid };
    const n = @min(pname.len, out.profile_buf.len);
    @memcpy(out.profile_buf[0..n], pname[0..n]);
    out.profile_len = n;
    return out;
}

fn writeActiveDesktop(cid: usize, profile_name: []const u8) void {
    makeParentDir(sysconfig.PERSONAL_CID_PATH);
    var buf: [128]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{d}:{s}\n", .{
        cid,
        profile_name,
    }) catch return;
    common.writeFile(sysconfig.PERSONAL_CID_PATH, line) catch {};
}

fn removeActiveDesktopFile() void {
    var z_buf: [common.MAX_PATH_LEN]u8 = undefined;
    if (common.toPathZ(sysconfig.PERSONAL_CID_PATH, &z_buf)) |z| {
        _ = linux.unlink(z.ptr);
    }
}

fn unbindPlatformDevice(spec: []const u8) void {
    if (spec.len == 0) return;
    const colon = std.mem.indexOfScalar(u8, spec, ':') orelse return;
    const drv = spec[0..colon];
    const dev = spec[colon + 1 ..];
    if (drv.len == 0 or dev.len == 0) return;

    const alloc = std.heap.page_allocator;
    const bound_path = alloc.print(
        "/sys/bus/platform/drivers/{s}/{s}",
        .{ drv, dev },
    ) catch return;
    defer alloc.free(bound_path);

    var z_buf: [common.MAX_PATH_LEN]u8 = undefined;
    const bz = common.toPathZ(bound_path, &z_buf) orelse return;
    if (!common.fileExistsPath(bz.ptr)) return;

    const unbind_path = alloc.print(
        "/sys/bus/platform/drivers/{s}/unbind",
        .{drv},
    ) catch return;
    defer alloc.free(unbind_path);
    const uz = common.toPathZ(unbind_path, &z_buf) orelse return;
    const fd_res = linux.open(uz.ptr, .{ .ACCMODE = .WRONLY }, 0);
    const fd_signed: isize = @bitCast(fd_res);
    if (fd_signed < 0) return;
    const fd: i32 = @intCast(fd_signed);
    defer _ = linux.close(fd);
    _ = linux.write(fd, dev.ptr, dev.len);
}

fn findLatestCidByName(name: []const u8) ?usize {
    const content = common.readBinaryFile(
        common.GUEST_REGISTRY_PATH,
        common.MAX_MANIFEST_SIZE,
    ) catch return null;
    defer common.unmapBinaryFile(content);

    var found: ?usize = null;
    var iter = common.GuestRegistryIter.init(content);
    while (iter.next()) |entry| {
        if (std.mem.eql(u8, entry.name, name)) found = entry.cid;
    }
    return found;
}

fn appendOptPair(
    allocator: std.mem.Allocator,
    argv: *std.ArrayList([*:0]const u8),
    strings: *vm_owned.OwnedStrings,
    flag: []const u8,
    val: []const u8,
) !void {
    try argv.append(allocator, (try strings.dupe(flag)).ptr);
    try argv.append(allocator, (try strings.dupe(val)).ptr);
}

pub fn startProfile(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    profile_arg: ?[]const u8,
    extra_args: []const [*:0]const u8,
) !void {
    if (readActiveDesktop(client)) |active| {
        common.printFmt(
            "Error: Desktop VM '{s}' (CID {d}) is already running. " ++
                "Use 'dsx personal switch <profile>' or 'dsx personal stop'.\n",
            .{ active.profile(), active.cid },
        );
        return;
    }

    var cfg = try loadEffectiveConfig(allocator);
    defer cfg.deinit();

    var prof = cfg.findProfile(profile_arg) orelse {
        common.printFmt(
            "Error: Unknown desktop profile '{s}'.\n",
            .{profile_arg.?},
        );
        return;
    };

    const StartOpt = enum {
        @"--image",
        @"--ram",
        @"--vcpus",
        @"--pcpu",
        @"--cmdline",
        @"--unbind",
        @"--dma-trusted",
        @"--mmio",
        @"--irq",
        @"--keep-fdt",
    };
    var extra_mmios: [16][]const u8 = @splat("");
    var extra_mmio_n: usize = 0;
    var extra_irqs: [32][]const u8 = @splat("");
    var extra_irq_n: usize = 0;
    var extra_keep: [16][]const u8 = @splat("");
    var extra_keep_n: usize = 0;
    var owned_strings = vm_owned.OwnedStrings.init(allocator);
    defer owned_strings.deinit();

    var i: usize = 0;
    while (i < extra_args.len) : (i += 1) {
        const s = std.mem.span(extra_args[i]);
        const opt = std.meta.stringToEnum(StartOpt, s) orelse continue;
        if (opt == .@"--dma-trusted") {
            prof.dma_trusted = true;
            continue;
        }
        if (i + 1 >= extra_args.len) continue;
        i += 1;
        const val = std.mem.span(extra_args[i]);
        switch (opt) {
            .@"--image" => prof.image = val,
            .@"--ram" => prof.ram_mb = std.fmt.parseInt(usize, val, 10) catch
                common.parseMemorySizeMb(val),
            .@"--vcpus" => prof.vcpus = std.fmt.parseInt(usize, val, 10) catch
                prof.vcpus,
            .@"--pcpu" => prof.cpu_pct = std.fmt.parseInt(usize, val, 10) catch
                prof.cpu_pct,
            .@"--cmdline" => prof.cmdline = val,
            .@"--unbind" => prof.unbind_platform = val,
            .@"--mmio" => if (extra_mmio_n < extra_mmios.len) {
                extra_mmios[extra_mmio_n] = val;
                extra_mmio_n += 1;
            },
            .@"--irq" => if (extra_irq_n < extra_irqs.len) {
                extra_irqs[extra_irq_n] = val;
                extra_irq_n += 1;
            },
            .@"--keep-fdt" => if (extra_keep_n < extra_keep.len) {
                extra_keep[extra_keep_n] = val;
                extra_keep_n += 1;
            },
            .@"--dma-trusted" => {},
        }
    }

    const mmio_list = if (extra_mmio_n > 0)
        extra_mmios[0..extra_mmio_n]
    else
        prof.mmio[0..prof.mmio_count];
    const irq_list = if (extra_irq_n > 0)
        extra_irqs[0..extra_irq_n]
    else
        prof.irq[0..prof.irq_count];
    const keep_list = if (extra_keep_n > 0)
        extra_keep[0..extra_keep_n]
    else
        prof.keep_fdt[0..prof.keep_fdt_count];

    for (mmio_list) |m| _ = vm_passthrough.parseMmioSpec(m) catch {
        common.printFmt("Error: Invalid mmio spec '{s}'.\n", .{m});
        return;
    };
    for (irq_list) |q| _ = vm_passthrough.parseIrqSpec(q) catch {
        common.printFmt("Error: Invalid irq spec '{s}'.\n", .{q});
        return;
    };

    unbindPlatformDevice(prof.unbind_platform);

    var argv = std.ArrayList([*:0]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, (try owned_strings.dupe(prof.image)).ptr);
    try appendOptPair(allocator, &argv, &owned_strings, "--name", prof.name);
    const vcpus_s = try owned_strings.print("{d}", .{prof.vcpus});
    try appendOptPair(allocator, &argv, &owned_strings, "--vcpus", vcpus_s);
    const ram_s = try owned_strings.print("{d}M", .{prof.ram_mb});
    try appendOptPair(allocator, &argv, &owned_strings, "--ram", ram_s);
    if (prof.cpu_pct > 0) {
        const pcpu_s = try owned_strings.print("{d}", .{prof.cpu_pct});
        try appendOptPair(allocator, &argv, &owned_strings, "--pcpu", pcpu_s);
    }
    if (prof.dma_trusted) {
        try argv.append(
            allocator,
            (try owned_strings.dupe("--dma-trusted")).ptr,
        );
    }
    if (prof.cmdline.len > 0) {
        try appendOptPair(
            allocator,
            &argv,
            &owned_strings,
            "--cmdline",
            prof.cmdline,
        );
    }
    for (mmio_list) |m| {
        try appendOptPair(allocator, &argv, &owned_strings, "--mmio", m);
    }
    for (irq_list) |q| {
        try appendOptPair(allocator, &argv, &owned_strings, "--irq", q);
    }
    for (keep_list) |k| {
        try appendOptPair(allocator, &argv, &owned_strings, "--keep-fdt", k);
    }

    try vm.cmdRun(client, argv.items);
    if (findLatestCidByName(prof.name)) |cid| {
        writeActiveDesktop(cid, prof.name);
        common.printFmt(
            "✓ Personal desktop profile '{s}' started (CID {d}).\n",
            .{ prof.name, cid },
        );
    }
}

pub fn stopActiveDesktop(client: *api.DiosixClient, quiet: bool) bool {
    const active = readActiveDesktop(client) orelse {
        if (!quiet) common.printStr("No active personal desktop VM running.\n");
        return true;
    };
    var cid_buf: [32]u8 = undefined;
    const cid_s = std.fmt.bufPrint(&cid_buf, "{d}", .{active.cid}) catch
        return false;
    var cid_z_buf: [33]u8 = undefined;
    const cid_z = common.toPathZ(cid_s, &cid_z_buf) orelse return false;
    const stop_args = [_][*:0]const u8{cid_z.ptr};
    const ok = vm.cmdStop(client, &stop_args) catch false;
    if (ok) {
        var poll: usize = 0;
        while (poll < STOP_POLL_ITERS) : (poll += 1) {
            _ = client.getInfo(active.cid) catch break;
            const ts = linux.timespec{ .sec = 0, .nsec = STOP_POLL_NS };
            _ = linux.nanosleep(&ts, null);
        }
        removeActiveDesktopFile();
    }
    return ok;
}
