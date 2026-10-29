// Diosix Hypervisor Guest Management CLI — VM Image & Manifest Staging.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const api = @import("../api.zig");
const manifest = @import("../manifest.zig");
const common = @import("../common.zig");
const loader = @import("../loader.zig");
const storage = @import("../storage.zig");
const sysconfig = @import("../sysconfig.zig");
const owned = @import("owned.zig");

const CID_SELF = common.CID_SELF;
const MAX_PATH_LEN = common.MAX_PATH_LEN;
const MAX_ELF_FILE_SIZE = common.MAX_ELF_FILE_SIZE;
const MAX_MANIFEST_SIZE = common.MAX_MANIFEST_SIZE;
const OwnedStrings = owned.OwnedStrings;
const OOM_MSG = owned.OOM_MSG;
const printStr = common.printStr;
const trimWhitespace = common.trimWhitespace;
const parseMemorySizeMb = common.parseMemorySizeMb;
const readBinaryFile = common.readBinaryFile;
const unmapBinaryFile = common.unmapBinaryFile;

/// Upper bound when reading a management public key file: an OpenSSH-style
/// public key line is a few hundred bytes, so one page is ample.
const MAX_PUBKEY_FILE_SIZE: usize = 4096;

const ImageAlias = enum {
    @"guest-shim",
    @"guest-shim.elf",
    @"guest-shim.bin",
    @"diosix-guest-shim.elf",
    default,
    @"default.elf",
    @"default.bin",
    @"diosix-base-linux",
    @"diosix-base-linux.elf",
    @"base-linux",
    @"diosix-linux",
    @"diosix-linux.elf",
};

/// Reads `<dir>/<name><ext>` as a mapped file, or returns null when it cannot
/// be read. Only a failure to build the path is reported as an error.
fn readCandidate(
    allocator: std.mem.Allocator,
    dir: []const u8,
    name: []const u8,
    ext: []const u8,
) error{OutOfMemory}!?[]u8 {
    const path = try allocator.print("{s}/{s}{s}", .{ dir, name, ext });
    defer allocator.free(path);
    return readBinaryFile(path, MAX_ELF_FILE_SIZE) catch null;
}

pub fn resolveElfImage(elf_path: []const u8) error{OutOfMemory}!?[]u8 {
    const allocator = std.heap.page_allocator;
    const sys_cfg = common.loadRuntimeSystemConfig();
    if (std.meta.stringToEnum(ImageAlias, elf_path)) |alias| {
        const default_paths = [_][]const u8{
            loader.DEFAULT_GUEST_IMAGE_PATH,
            sysconfig.LEGACY_GUEST_IMAGE_PATH,
            loader.FALLBACK_GUEST_IMAGE_PATH,
        };
        switch (alias) {
            .@"guest-shim",
            .@"guest-shim.elf",
            .@"guest-shim.bin",
            .@"diosix-guest-shim.elf",
            => {
                for (sysconfig.GUEST_SHIM_PATHS) |shim_cand| {
                    if (readBinaryFile(shim_cand, MAX_ELF_FILE_SIZE)) |data| {
                        return data;
                    } else |_| {}
                }
            },
            else => {},
        }
        for (default_paths) |cand| {
            if (readBinaryFile(cand, MAX_ELF_FILE_SIZE)) |data| {
                return data;
            } else |_| {}
        }
    }

    if (readBinaryFile(elf_path, MAX_ELF_FILE_SIZE)) |data| {
        return data;
    } else |_| {}

    const search_dirs = [_][]const u8{
        sys_cfg.imagesDir(),
        sysconfig.GUEST_SHIM_DIR,
    };
    const has_elf_ext = std.mem.endsWith(u8, elf_path, ".elf") or
        std.mem.endsWith(u8, elf_path, ".bin");
    for (search_dirs) |dir| {
        if (try readCandidate(allocator, dir, elf_path, "")) |data| {
            return data;
        }
        if (!has_elf_ext) {
            if (try readCandidate(allocator, dir, elf_path, ".elf")) |data| {
                return data;
            }
            if (try readCandidate(allocator, dir, elf_path, ".bin")) |data| {
                return data;
            }
        }
    }
    return null;
}

pub fn stageChildVmManifest(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    child_cid: usize,
    vm_name: []const u8,
    domain_name: ?[]const u8,
    manifest_path: ?[]const u8,
) void {
    const sys_cfg = common.loadRuntimeSystemConfig();
    var pubkey_line: []const u8 = "";
    var pk_mapped: ?[]u8 = null;
    defer if (pk_mapped) |m| unmapBinaryFile(m);
    const cfg_pk = allocator.print(
        "{s}/id_management.pub",
        .{sys_cfg.keysDir()},
    ) catch {
        printStr(OOM_MSG);
        return;
    };
    defer allocator.free(cfg_pk);
    const pubkey_candidates = [_][]const u8{
        cfg_pk,
        sysconfig.ETC_MANAGEMENT_PUBKEY_PATH,
    };
    for (pubkey_candidates) |cand| {
        if (readBinaryFile(cand, MAX_PUBKEY_FILE_SIZE)) |pk_bytes| {
            const trimmed = trimWhitespace(pk_bytes);
            if (trimmed.len > 0) {
                pk_mapped = pk_bytes;
                pubkey_line = trimmed;
                break;
            }
            unmapBinaryFile(pk_bytes);
        } else |_| {}
    }

    var staged = std.ArrayList(u8).empty;
    defer staged.deinit(allocator);
    if (pubkey_line.len > 0) {
        const hdr = allocator.print(
            "# diosix-authorized-key: {s}\n",
            .{pubkey_line},
        ) catch {
            printStr(OOM_MSG);
            return;
        };
        defer allocator.free(hdr);
        staged.appendSlice(allocator, hdr) catch {
            printStr(OOM_MSG);
            return;
        };
    }

    var wrote_domain_manifest = false;
    if (domain_name) |dname| {
        const m_file = manifest_path orelse sys_cfg.systemManifestPath();
        if (readBinaryFile(m_file, MAX_MANIFEST_SIZE)) |m_content| {
            defer unmapBinaryFile(m_content);
            if (manifest.parseSystemManifest(allocator, m_content)) |sys_m_v| {
                var sys_m = sys_m_v;
                defer sys_m.deinit();
                if (manifest.pruneSystemManifest(
                    allocator,
                    &sys_m,
                    dname,
                    child_cid,
                    CID_SELF,
                    null,
                )) |child_m_v| {
                    var child_m = child_m_v;
                    defer child_m.deinit();
                    if (manifest.serializeChildManifest(
                        allocator,
                        &child_m,
                    )) |child_toml| {
                        defer allocator.free(child_toml);
                        if (staged.appendSlice(allocator, child_toml)) |_| {
                            wrote_domain_manifest = true;
                        } else |_| {}
                    } else |_| {}
                } else |_| {}
            } else |_| {}
        } else |_| {}
    }

    if (!wrote_domain_manifest) {
        var vcpus: usize = 1;
        var ram_mb: usize = 256;
        var pool_mb: usize = 256;
        var pcpu_pct: u32 = api.DEFAULT_CHILD_PCPU_QUOTA_PCT;
        if (client.getInfo(child_cid)) |ci| {
            if (ci.vcpus > 0) vcpus = ci.vcpus;
            if (ci.self_ram_pages > 0) ram_mb = ci.self_ram_pages / 256;
            pool_mb = if (ci.max_ram_pages > 0 and
                ci.max_ram_pages < std.math.maxInt(usize) / 2)
                ci.max_ram_pages / 256
            else
                ram_mb;
            if (ci.pcpu_quota_pct > 0) pcpu_pct = ci.pcpu_quota_pct;
        } else |_| {}
        const fallback_m = allocator.print(
            "[vm]\nname = \"{s}\"\ncid = {d}\nparent_cid = 0\n" ++
                "vcpus = {d}\nram = \"{d} MB\"\nram_pool = \"{d} MB\"\n" ++
                "pcpu_pool_pct = {d}\n",
            .{ vm_name, child_cid, vcpus, ram_mb, pool_mb, pcpu_pct },
        ) catch return printStr(OOM_MSG);
        defer allocator.free(fallback_m);
        staged.appendSlice(allocator, fallback_m) catch
            return printStr(OOM_MSG);
    }

    if (staged.items.len > 0) {
        _ = client.setManifest(child_cid, staged.items) catch {};
    }
}

/// Fills options the user left unset from a manifest domain. The manifest is
/// unmapped after lookup, so every borrowed field is copied into `strings`.
pub fn copyDomainFields(
    strings: *OwnedStrings,
    dom: manifest.DomainSpec,
    elf_path: *?[]const u8,
    ram_str: *[]const u8,
    disk_str: *?[]const u8,
    cdrom_str: *?[]const u8,
    ip_str: *[]const u8,
) !void {
    if (elf_path.* == null and dom.image.len > 0) {
        elf_path.* = try strings.dupe(dom.image);
    }
    const is_def_ram = std.mem.eql(u8, ram_str.*, "256 MB");
    if (dom.ram.len > 0 and is_def_ram) {
        ram_str.* = try strings.dupe(dom.ram);
    }
    if (disk_str.* == null and dom.disk.len > 0) {
        disk_str.* = try strings.dupe(dom.disk);
    }
    if (cdrom_str.* == null and dom.cdrom.len > 0) {
        cdrom_str.* = try strings.dupe(dom.cdrom);
    }
    if (dom.ip.len > 0 and ip_str.len == 0) {
        ip_str.* = try strings.dupe(dom.ip);
    }
}

/// Formats a path into `buf`, reporting overflow instead of truncating.
fn formatPath(
    buf: *[MAX_PATH_LEN]u8,
    comptime fmt: []const u8,
    args: anytype,
) error{PathTooLong}![]const u8 {
    return std.fmt.bufPrint(buf, fmt, args) catch error.PathTooLong;
}

/// Copies `path` into `buf`, reporting overflow instead of truncating.
fn copyPath(
    buf: *[MAX_PATH_LEN]u8,
    path: []const u8,
) error{PathTooLong}![]const u8 {
    return formatPath(buf, "{s}", .{path});
}

/// Resolves the `--disk` option to a path stored in `final_disk_buf` (or
/// borrowed from `disk_str`). `final_disk_buf` is also the scratch space the
/// storage layer provisions disks into.
pub fn resolveRunDisk(
    disk_str: ?[]const u8,
    vm_name: []const u8,
    final_disk_buf: *[MAX_PATH_LEN]u8,
) error{ PathTooLong, OutOfMemory }![]const u8 {
    const sys_cfg = common.loadRuntimeSystemConfig();
    const disks_dir = sys_cfg.disksDir();
    const d = disk_str orelse return "";
    if (std.mem.startsWith(u8, d, "/")) return d;
    if (d.len > 0 and std.ascii.isDigit(d[0])) {
        const d_mb = parseMemorySizeMb(d);
        if (storage.provisionVirtualDisk(vm_name, d_mb, final_disk_buf)) |p| {
            return p;
        }
        return formatPath(
            final_disk_buf,
            "{s}/{s}.img",
            .{ disks_dir, vm_name },
        );
    }
    const disk_base = if (std.mem.endsWith(u8, d, ".img") or
        std.mem.endsWith(u8, d, ".raw"))
        d[0 .. d.len - 4]
    else
        d;
    const allocator = std.heap.page_allocator;
    const test_path = try allocator.print(
        "{s}/{s}.img",
        .{ disks_dir, disk_base },
    );
    defer allocator.free(test_path);
    var strings = OwnedStrings.init(allocator);
    defer strings.deinit();
    const z_test = try strings.dupe(test_path);
    if (common.fileExistsPath(z_test.ptr)) {
        return copyPath(final_disk_buf, test_path);
    }
    return storage.provisionVirtualDisk(
        disk_base,
        sys_cfg.default_disk_mb,
        final_disk_buf,
    ) orelse try copyPath(final_disk_buf, test_path);
}

pub fn checkChildResourceQuota(
    client: *api.DiosixClient,
    vm_name: []const u8,
    vcpus: usize,
    ram_mb: usize,
    req_pcpu_pct: usize,
    ram_quota_mb: usize,
) ?usize {
    const default_pcpu: usize = api.DEFAULT_CHILD_PCPU_QUOTA_PCT;
    const info = client.getInfo(CID_SELF) catch {
        const eff_pcpu = if (req_pcpu_pct > 0) req_pcpu_pct else default_pcpu;
        common.printFmt(
            "[25%] Allocating child VM '{s}' ({d} vCPUs, {d} MB RAM, " ++
                "{d}% pCPU, {d} MB RAM quota)...\n",
            .{ vm_name, vcpus, ram_mb, eff_pcpu, ram_quota_mb },
        );
        return eff_pcpu;
    };

    const max_pcpu: usize = if (info.is_root != 0 and
        info.pcpu_quota_pct > 0 and info.pcpu_quota_pct < 100)
        info.pcpu_quota_pct
    else
        api.MAX_CHILD_PCPU_QUOTA_PCT;
    const del_pcpu: usize = @min(@as(usize, info.delegated_pcpu_pct), max_pcpu);
    const avail_pcpu: usize = max_pcpu -| del_pcpu;
    const eff_pcpu: usize = if (req_pcpu_pct > 0)
        req_pcpu_pct
    else
        @min(default_pcpu, avail_pcpu);

    if (avail_pcpu == 0 or eff_pcpu == 0 or eff_pcpu > avail_pcpu) {
        common.printFmt(
            "Error: Create child VM failed: pCPU quota exhausted " ++
                "({d}%/{d}% delegated, {d}% requested).\n",
            .{ del_pcpu, max_pcpu, if (req_pcpu_pct > 0) req_pcpu_pct else 1 },
        );
        return null;
    }

    const self_ram_mb = (info.self_ram_pages * common.PAGE_SIZE_KB) /
        common.KB_PER_MB;
    const max_ram_mb = (info.max_ram_pages * common.PAGE_SIZE_KB) /
        common.KB_PER_MB;
    const del_ram_mb = (info.delegated_ram_pages * common.PAGE_SIZE_KB) /
        common.KB_PER_MB;
    const used_ram_mb = (info.used_ram_pages * common.PAGE_SIZE_KB) /
        common.KB_PER_MB;
    if (max_ram_mb > 0 and max_ram_mb < std.math.maxInt(usize) / 2) {
        const avail_ram_mb = if (info.is_root != 0)
            max_ram_mb -| @max(del_ram_mb, used_ram_mb)
        else
            max_ram_mb -| @max(self_ram_mb +| del_ram_mb, used_ram_mb);
        if (ram_quota_mb > avail_ram_mb) {
            common.printFmt(
                "Error: Create child VM failed: RAM quota exhausted " ++
                    "({d} MB available, {d} MB requested).\n",
                .{ avail_ram_mb, ram_quota_mb },
            );
            return null;
        }
    }

    common.printFmt(
        "[25%] Allocating child VM '{s}' ({d} vCPUs, {d} MB RAM, " ++
            "{d}% pCPU, {d} MB RAM quota)...\n",
        .{ vm_name, vcpus, ram_mb, eff_pcpu, ram_quota_mb },
    );
    return eff_pcpu;
}

pub fn printRunSuccess(
    vm_name: []const u8,
    child_cid: usize,
    vcpus: usize,
    ram_str: []const u8,
    disk: []const u8,
    cdrom: []const u8,
    ip: []const u8,
) void {
    if (disk.len > 0 and cdrom.len > 0) {
        common.printFmt(
            "✓ Child VM '{s}' (CID {d}, {d} vCPUs, {s} RAM, " ++
                "Disk: {s}, CD-ROM: {s}, IP: {s}) started in background.\n",
            .{ vm_name, child_cid, vcpus, ram_str, disk, cdrom, ip },
        );
    } else if (disk.len > 0) {
        common.printFmt(
            "✓ Child VM '{s}' (CID {d}, {d} vCPUs, {s} RAM, " ++
                "Disk: {s}, IP: {s}) started in background.\n",
            .{ vm_name, child_cid, vcpus, ram_str, disk, ip },
        );
    } else if (cdrom.len > 0) {
        common.printFmt(
            "✓ Child VM '{s}' (CID {d}, {d} vCPUs, {s} RAM, " ++
                "CD-ROM: {s}, IP: {s}) started in background.\n",
            .{ vm_name, child_cid, vcpus, ram_str, cdrom, ip },
        );
    } else {
        common.printFmt(
            "✓ Child VM '{s}' (CID {d}, {d} vCPUs, {s} RAM, " ++
                "IP: {s}) started in background.\n",
            .{ vm_name, child_cid, vcpus, ram_str, ip },
        );
    }
}

test "vm_stage: resolveRunDisk returns empty slice when disk_str is null" {
    std.testing.refAllDecls(@This());
    var buf: [MAX_PATH_LEN]u8 = undefined;
    const out = try resolveRunDisk(null, "test", &buf);
    try std.testing.expectEqualStrings("", out);
}

test "vm_stage: formatPath reports overflow instead of truncating" {
    var buf: [MAX_PATH_LEN]u8 = undefined;
    const too_long: [MAX_PATH_LEN + 1]u8 = @splat('d');
    try std.testing.expectEqualStrings(
        "/disks/a.img",
        try formatPath(&buf, "{s}/{s}.img", .{ "/disks", "a" }),
    );
    try std.testing.expectError(
        error.PathTooLong,
        copyPath(&buf, &too_long),
    );
}

test "vm_stage: copyDomainFields keeps long fields and user options" {
    var strings = OwnedStrings.init(std.testing.allocator);
    defer strings.deinit();

    const long_image: [MAX_PATH_LEN + 1]u8 = @splat('i');
    var dom = manifest.DomainSpec.init("web");
    dom.image = &long_image;
    dom.ram = "512M";
    dom.disk = "web-disk";
    var elf_path: ?[]const u8 = null;
    var ram_str: []const u8 = "256 MB";
    var disk_str: ?[]const u8 = "user-disk";
    var cdrom_str: ?[]const u8 = null;
    var ip_str: []const u8 = "";
    try copyDomainFields(
        &strings,
        dom,
        &elf_path,
        &ram_str,
        &disk_str,
        &cdrom_str,
        &ip_str,
    );
    try std.testing.expectEqualStrings(&long_image, elf_path.?);
    try std.testing.expectEqualStrings("512M", ram_str);
    try std.testing.expectEqualStrings("user-disk", disk_str.?);
    try std.testing.expect(cdrom_str == null);
    try std.testing.expectEqual(@as(usize, 0), ip_str.len);
}
