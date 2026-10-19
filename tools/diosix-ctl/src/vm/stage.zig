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

const CID_SELF = common.CID_SELF;
const MAX_PATH_LEN = common.MAX_PATH_LEN;
const MAX_ELF_FILE_SIZE = common.MAX_ELF_FILE_SIZE;
const MAX_MANIFEST_SIZE = common.MAX_MANIFEST_SIZE;
const trimWhitespace = common.trimWhitespace;
const parseMemorySizeMb = common.parseMemorySizeMb;
const readBinaryFile = common.readBinaryFile;
const unmapBinaryFile = common.unmapBinaryFile;

const ImageAlias = enum {
    @"guest-shim",
    @"guest-shim.elf",
    @"diosix-guest-shim.elf",
    default,
    @"default.elf",
};

pub fn resolveElfImage(
    elf_path: []const u8,
    resolved_buf: *[MAX_PATH_LEN]u8,
) ?[]u8 {
    if (std.meta.stringToEnum(ImageAlias, elf_path)) |alias| {
        switch (alias) {
            .@"guest-shim", .@"guest-shim.elf", .@"diosix-guest-shim.elf" => {
                for (loader.GUEST_SHIM_CANDIDATES) |cand| {
                    if (readBinaryFile(cand, MAX_ELF_FILE_SIZE)) |data| {
                        return data;
                    } else |_| {}
                }
                for (loader.DEFAULT_GUEST_CANDIDATES) |cand| {
                    if (readBinaryFile(cand, MAX_ELF_FILE_SIZE)) |data| {
                        return data;
                    } else |_| {}
                }
            },
            .default, .@"default.elf" => {
                for (loader.DEFAULT_GUEST_CANDIDATES) |cand| {
                    if (readBinaryFile(cand, MAX_ELF_FILE_SIZE)) |data| {
                        return data;
                    } else |_| {}
                }
            },
        }
    }

    if (readBinaryFile(elf_path, MAX_ELF_FILE_SIZE)) |data| {
        return data;
    } else |_| {}

    const search_prefixes = [_][]const u8{
        "/var/lib/diosix/images/",
        "/usr/share/diosix/shim/",
        "/boot/",
    };
    for (search_prefixes) |prefix| {
        if (prefix.len + elf_path.len < resolved_buf.len) {
            @memcpy(resolved_buf[0..prefix.len], prefix);
            @memcpy(
                resolved_buf[prefix.len .. prefix.len + elf_path.len],
                elf_path,
            );
            const cand = resolved_buf[0 .. prefix.len + elf_path.len];
            if (readBinaryFile(cand, MAX_ELF_FILE_SIZE)) |data| {
                return data;
            } else |_| {}

            if (prefix.len + elf_path.len + 4 < resolved_buf.len and
                !std.mem.endsWith(u8, elf_path, ".elf"))
            {
                const end = prefix.len + elf_path.len;
                @memcpy(resolved_buf[end .. end + 4], ".elf");
                const cand_elf = resolved_buf[0 .. end + 4];
                if (readBinaryFile(cand_elf, MAX_ELF_FILE_SIZE)) |data| {
                    return data;
                } else |_| {}
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
    var pubkey_line: []const u8 = "";
    var pk_mapped: ?[]u8 = null;
    defer if (pk_mapped) |m| unmapBinaryFile(m);
    const pubkey_candidates = [_][]const u8{
        "/var/lib/diosix/keys/id_management.pub",
        "/etc/diosix/keys/id_management.pub",
    };
    for (pubkey_candidates) |cand| {
        if (readBinaryFile(cand, 4096)) |pk_bytes| {
            const trimmed = trimWhitespace(pk_bytes);
            if (trimmed.len > 0) {
                pk_mapped = pk_bytes;
                pubkey_line = trimmed;
                break;
            }
            unmapBinaryFile(pk_bytes);
        } else |_| {}
    }

    var staged_buf: [4096]u8 = undefined;
    var staged_len: usize = 0;
    if (pubkey_line.len > 0) {
        if (std.fmt.bufPrint(
            staged_buf[0..],
            "# diosix-authorized-key: {s}\n",
            .{pubkey_line},
        )) |hdr| {
            staged_len += hdr.len;
        } else |_| {}
    }

    var wrote_domain_manifest = false;
    if (domain_name) |dname| {
        const m_file = manifest_path orelse "/etc/diosix/system.toml";
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
                        if (staged_len + child_toml.len <= staged_buf.len) {
                            @memcpy(
                                staged_buf[staged_len .. staged_len +
                                    child_toml.len],
                                child_toml,
                            );
                            staged_len += child_toml.len;
                            wrote_domain_manifest = true;
                        }
                    } else |_| {}
                } else |_| {}
            } else |_| {}
        } else |_| {}
    }

    if (!wrote_domain_manifest) {
        if (std.fmt.bufPrint(
            staged_buf[staged_len..],
            "[vm]\nname = \"{s}\"\ncid = {d}\nparent_cid = 0\n",
            .{ vm_name, child_cid },
        )) |fallback_m| {
            staged_len += fallback_m.len;
        } else |_| {}
    }

    if (staged_len > 0) {
        _ = client.setManifest(child_cid, staged_buf[0..staged_len]) catch {};
    }
}

pub fn resolveRunDisk(
    disk_str: ?[]const u8,
    vm_name: []const u8,
    final_disk_buf: *[MAX_PATH_LEN]u8,
) []const u8 {
    const d = disk_str orelse return "";
    if (std.mem.startsWith(u8, d, "/")) return d;
    if (d.len > 0 and std.ascii.isDigit(d[0])) {
        const d_mb = parseMemorySizeMb(d);
        if (storage.provisionVirtualDisk(vm_name, d_mb, final_disk_buf)) |p| {
            return p;
        }
        return std.fmt.bufPrint(
            final_disk_buf,
            "/var/lib/diosix/disks/{s}.img",
            .{vm_name},
        ) catch "/var/lib/diosix/disks/disk.img";
    }
    const disk_base = if (std.mem.endsWith(u8, d, ".img") or
        std.mem.endsWith(u8, d, ".raw"))
        d[0 .. d.len - 4]
    else
        d;
    var test_buf: [MAX_PATH_LEN]u8 = undefined;
    const test_path = std.fmt.bufPrint(
        &test_buf,
        "/var/lib/diosix/disks/{s}.img",
        .{disk_base},
    ) catch "/var/lib/diosix/disks/disk.img";
    var z_buf: [MAX_PATH_LEN]u8 = undefined;
    if (common.toPathZ(test_path, &z_buf)) |z_test| {
        if (common.fileExistsPath(z_test.ptr)) {
            return std.fmt.bufPrint(final_disk_buf, "{s}", .{test_path}) catch
                test_path;
        }
    }
    return storage.provisionVirtualDisk(disk_base, 1024, final_disk_buf) orelse
        std.fmt.bufPrint(final_disk_buf, "{s}", .{test_path}) catch test_path;
}

test "vm_stage: resolveRunDisk returns empty slice when disk_str is null" {
    std.testing.refAllDecls(@This());
    var buf: [MAX_PATH_LEN]u8 = undefined;
    try std.testing.expectEqualStrings("", resolveRunDisk(null, "test", &buf));
}
