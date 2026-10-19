// Diosix Hypervisor Guest Management CLI — Unit & Integration Tests.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const testing = std.testing;
const main = @import("../main.zig");
const api = main.api;
const manifest = main.manifest;
const catalog = main.catalog;
const passkey = main.passkey;
const installer = main.installer;
const charter = main.charter;
const sysconfig = main.sysconfig;
const common = main.common;
const loader = main.loader;
const ssh = main.ssh;
const storage = main.storage;
const vm = main.vm;
const host = main.host;
const governance = main.governance;

const CID_PARENT = common.CID_PARENT;
const CID_SELF = common.CID_SELF;
const MAX_PATH_LEN = common.MAX_PATH_LEN;
const MAX_MANIFEST_SIZE = common.MAX_MANIFEST_SIZE;
const parseCid = common.parseCid;
const isArch = common.isArch;
const parseMemorySizeMb = common.parseMemorySizeMb;
const readBinaryFile = common.readBinaryFile;
const unmapBinaryFile = common.unmapBinaryFile;
const matchTarget = common.matchTarget;
const formatSelfInfo = vm.formatSelfInfo;
const formatVersionChannel = host.formatVersionChannel;
const formatHostInfo = host.formatHostInfo;

test {
    testing.refAllDecls(@This());
    testing.refAllDecls(api);
    testing.refAllDecls(manifest);
    testing.refAllDecls(catalog);
    testing.refAllDecls(passkey);
    testing.refAllDecls(installer);
    testing.refAllDecls(charter);
    testing.refAllDecls(sysconfig);
    testing.refAllDecls(common);
    testing.refAllDecls(loader);
    testing.refAllDecls(ssh);
    testing.refAllDecls(storage);
    testing.refAllDecls(vm);
    testing.refAllDecls(host);
    testing.refAllDecls(governance);
}

test "parseCid resolution" {
    try testing.expectEqual(CID_SELF, try parseCid("self"));
    try testing.expectEqual(CID_PARENT, try parseCid("parent"));
    try testing.expectEqual(@as(usize, 2), try parseCid("2"));
    try testing.expectEqual(@as(usize, 42), try parseCid("42"));
    try testing.expectError(error.InvalidCharacter, parseCid("invalid"));
}

test "isArch target detection" {
    try testing.expect(isArch("riscv64"));
    try testing.expect(isArch("riscv32"));
    try testing.expect(isArch("aarch64"));
    try testing.expect(isArch("x86_64"));
    try testing.expect(!isArch("x86"));
    try testing.expect(!isArch("arm"));
    try testing.expect(!isArch("mips"));
    try testing.expect(!isArch("other"));
}

test "parseMemorySizeMb unit conversions" {
    try testing.expectEqual(@as(usize, 256), parseMemorySizeMb("256 MB"));
    try testing.expectEqual(@as(usize, 256), parseMemorySizeMb("256MB"));
    try testing.expectEqual(@as(usize, 256), parseMemorySizeMb("256M"));
    try testing.expectEqual(@as(usize, 2048), parseMemorySizeMb("2GiB"));
    try testing.expectEqual(@as(usize, 2048), parseMemorySizeMb("2GB"));
    try testing.expectEqual(@as(usize, 2048), parseMemorySizeMb("2G"));
    try testing.expectEqual(@as(usize, 1), parseMemorySizeMb("1024KB"));
    try testing.expectEqual(@as(usize, 1), parseMemorySizeMb("1024K"));
    try testing.expectEqual(@as(usize, 512), parseMemorySizeMb("512"));
}

test "readBinaryFile error handling" {
    try testing.expectError(
        error.FileNotFound,
        readBinaryFile("/nonexistent/file/path/here.bin", 4096),
    );

    const content = try readBinaryFile("VERSION", 1024);
    defer unmapBinaryFile(content);
    try testing.expect(content.len > 0);
}

test "guest registry serialization and query parsing" {
    const test_registry =
        \\[[guests]]
        \\cid = 2
        \\name = "user"
        \\vcpus = 2
        \\ram = "256 MB"
        \\ip = "10.0.3.2"
        \\trust = "untrusted"
        \\status = "running"
        \\
        \\[[guests]]
        \\cid = 3
        \\name = "sys-domain"
        \\vcpus = 4
        \\ram = "2GiB"
        \\ip = "10.0.3.3"
        \\trust = "trusted"
        \\status = "running"
        \\
    ;

    var iter = common.GuestRegistryIter.init(test_registry);
    var guest_count: usize = 0;
    var found_user = false;
    var found_sys = false;

    while (iter.next()) |entry| {
        guest_count += 1;
        if (std.mem.eql(u8, entry.name, "user")) found_user = true;
        if (std.mem.eql(u8, entry.name, "sys-domain")) found_sys = true;
    }

    try testing.expectEqual(@as(usize, 2), guest_count);
    try testing.expect(found_user);
    try testing.expect(found_sys);
}

test "matchTarget resolution" {
    try testing.expect(matchTarget("user", 0, 2, "user"));
    try testing.expect(matchTarget("user", 2, 2, "user"));
    try testing.expect(matchTarget("2", 2, 2, "user"));
    try testing.expect(matchTarget("sys", 0, 3, "sys-domain"));
    try testing.expect(!matchTarget("other", 0, 2, "user"));
}

test "RAM string formatting normalization" {
    var buf1: [32]u8 = undefined;
    var buf2: [32]u8 = undefined;
    var buf3: [32]u8 = undefined;

    const s1 = std.fmt.bufPrint(
        &buf1,
        "{d} MB",
        .{parseMemorySizeMb("256M")},
    ) catch "";
    const s2 = std.fmt.bufPrint(
        &buf2,
        "{d} MB",
        .{parseMemorySizeMb("512 MB")},
    ) catch "";
    const s3 = std.fmt.bufPrint(
        &buf3,
        "{d} MB",
        .{parseMemorySizeMb("2GiB")},
    ) catch "";

    try testing.expectEqualStrings("256 MB", s1);
    try testing.expectEqualStrings("512 MB", s2);
    try testing.expectEqualStrings("2048 MB", s3);
}

test "disk path and capacity resolution" {
    var path_buf: [MAX_PATH_LEN]u8 = undefined;
    const disk_name = "user-data";
    const full_path = std.fmt.bufPrint(
        &path_buf,
        "/var/lib/diosix/disks/{s}.img",
        .{disk_name},
    ) catch "";
    try testing.expectEqualStrings(
        "/var/lib/diosix/disks/user-data.img",
        full_path,
    );

    const size_2g = parseMemorySizeMb("2G");
    try testing.expectEqual(@as(usize, 2048), size_2g);
    const size_512m = parseMemorySizeMb("512M");
    try testing.expectEqual(@as(usize, 512), size_512m);
}

test "snapshot path resolution" {
    var snap_buf: [MAX_PATH_LEN]u8 = undefined;
    const snap_path = std.fmt.bufPrint(
        &snap_buf,
        "/var/lib/diosix/snapshots/{s}_{s}.snap",
        .{ "leenix", "checkpoint-1" },
    ) catch "";
    try testing.expectEqualStrings(
        "/var/lib/diosix/snapshots/leenix_checkpoint-1.snap",
        snap_path,
    );
}

test "image and cdrom path resolution" {
    var iso_buf: [MAX_PATH_LEN]u8 = undefined;
    const iso_name = "debian-12-netinst";
    const full_iso_path = std.fmt.bufPrint(
        &iso_buf,
        "/var/lib/diosix/iso/{s}.iso",
        .{iso_name},
    ) catch "";
    try testing.expectEqualStrings(
        "/var/lib/diosix/iso/debian-12-netinst.iso",
        full_iso_path,
    );

    var img_buf: [MAX_PATH_LEN]u8 = undefined;
    const img_name = "debian-installer";
    const full_img_path = std.fmt.bufPrint(
        &img_buf,
        "/var/lib/diosix/images/{s}.elf",
        .{img_name},
    ) catch "";
    try testing.expectEqualStrings(
        "/var/lib/diosix/images/debian-installer.elf",
        full_img_path,
    );
}

test "formatVersionChannel CalVer formatting" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings(
        "26.1",
        formatVersionChannel(&buf, 26, 1, 0),
    );
    try testing.expectEqualStrings(
        "26.2",
        formatVersionChannel(&buf, 26, 2, 0),
    );
    try testing.expectEqualStrings(
        "26.2.1",
        formatVersionChannel(&buf, 26, 2, 1),
    );
}

test "formatSelfInfo omits context and parent IDs and supports JSON" {
    const info = api.GuestInfo{
        .guest_id = 1,
        .parent_id = 0,
        .is_trusted = 1,
        .is_root = 1,
        .target_arch = 1,
        .assigned_cid = 1,
        .vcpus = 4,
        .self_ram_pages = (256 * 1024) / 4,
        .used_vcpus = 4,
        .max_vcpus = 0,
        .used_ram_pages = (128 * 1024) / 4,
        .max_ram_pages = 0,
        .child_count = 0,
    };

    var text_buf: [512]u8 = undefined;
    const text_out = formatSelfInfo(&text_buf, info, false);
    try testing.expect(std.mem.indexOf(u8, text_out, "Context ID") == null);
    try testing.expect(std.mem.indexOf(u8, text_out, "Parent CID") == null);
    try testing.expect(
        std.mem.indexOf(u8, text_out, "Root VM        : yes") != null,
    );
    try testing.expect(
        std.mem.indexOf(
            u8,
            text_out,
            "RAM allocation : 256 MB (65536 pages)",
        ) != null,
    );

    var json_buf: [512]u8 = undefined;
    const json_out = formatSelfInfo(&json_buf, info, true);
    try testing.expect(
        std.mem.indexOf(u8, json_out, "\"root_vm\":true") != null,
    );
    try testing.expect(
        std.mem.indexOf(u8, json_out, "\"ram_mb\":256") != null,
    );
}

test "formatHostInfo text and JSON output with injection sanitization" {
    var info = api.HypervisorInfo{
        .version_major = 26,
        .version_minor = 2,
        .version_patch = 1,
        .features = api.HypervisorFeature.HARDWARE_VIRT |
            api.HypervisorFeature.VIRTIO_VSOCK |
            api.HypervisorFeature.RELEASE_STABLE |
            api.HypervisorFeature.CHARTER_SEALED,
        .host_physical_cores = 4,
        .host_total_ram_kb = 2048 * 1024,
        .host_free_ram_kb = 1536 * 1024,
        .hv_reserved_bytes = 512 * 1024,
        .hv_heap_free_bytes = 256 * 1024,
    };
    @memcpy(info.build_commit[0..9], "a1b2c3d\"\\");
    @memcpy(info.host_cpu_isa[0..7], "RV64GC\n");
    const desc =
        "Version 26.2.1 (stable) oct26-review/a1b2c3d Sun Oct 18 2026 " ++
        "chris@violet (Zig 0.17.0 riscv64)";
    @memcpy(info.build_desc[0..desc.len], desc);

    var text_buf: [1024]u8 = undefined;
    const text_out = formatHostInfo(&text_buf, info, false);
    try testing.expect(std.mem.indexOf(u8, text_out, "Diosix version") == null);
    try testing.expect(
        std.mem.indexOf(
            u8,
            text_out,
            "Hypervisor build : Version 26.2.1 (stable) oct26-review/a1b2c3d",
        ) != null,
    );
    try testing.expect(
        std.mem.indexOf(
            u8,
            text_out,
            "[x] Hardware H-extension (nested virtualization)",
        ) != null,
    );
    try testing.expect(
        std.mem.indexOf(
            u8,
            text_out,
            "[x] VirtIO-vsock (AF_VSOCK in-hypervisor networking)",
        ) != null,
    );
    try testing.expect(
        std.mem.indexOf(
            u8,
            text_out,
            "[x] Constitutional Charter sealed in M-mode",
        ) != null,
    );

    var json_buf: [1024]u8 = undefined;
    const json_out = formatHostInfo(&json_buf, info, true);
    try testing.expect(
        std.mem.indexOf(u8, json_out, "\"version\":\"26.2.1\"") != null,
    );
    try testing.expect(
        std.mem.indexOf(u8, json_out, "\"channel\":\"stable\"") != null,
    );
    try testing.expect(
        std.mem.indexOf(u8, json_out, "\"branch\":\"oct26-review\"") != null,
    );
    try testing.expect(
        std.mem.indexOf(u8, json_out, "\"commit\":\"a1b2c3d\"") != null,
    );
    try testing.expect(
        std.mem.indexOf(u8, json_out, "\"isa\":\"RV64GC\"") != null,
    );
    try testing.expect(
        std.mem.indexOf(u8, json_out, "\"charter_sealed\":true") != null,
    );
}

test "loader candidate lists and SHIM_HEADER_MAGIC are configured" {
    try testing.expect(loader.GUEST_SHIM_CANDIDATES.len >= 3);
    try testing.expect(loader.DEFAULT_GUEST_CANDIDATES.len >= 5);
    try testing.expect(loader.FALLBACK_ISO_CANDIDATES.len >= 2);
    try testing.expectEqual(
        @as(u64, 0x4d49_4853_5853_4f44),
        loader.SHIM_HEADER_MAGIC,
    );
}

test "parseProposalAction and shipped TOML configs parse cleanly" {
    try testing.expectEqual(
        charter.ProposalAction.amend_charter,
        governance.parseProposalAction("amend-charter").?,
    );
    try testing.expectEqual(
        charter.ProposalAction.terminate_steward,
        governance.parseProposalAction("retire-steward").?,
    );
    try testing.expectEqual(
        charter.ProposalAction.reset_steward,
        governance.parseProposalAction("reset-steward").?,
    );
    try testing.expectEqual(
        charter.ProposalAction.root_failover,
        governance.parseProposalAction("promote-standby-root").?,
    );
    try testing.expectEqual(
        charter.ProposalAction.terminate_units,
        governance.parseProposalAction("terminate-vm").?,
    );
    try testing.expect(
        governance.parseProposalAction("unknown-action") == null,
    );

    const shipped_charter = try readBinaryFile(
        "tools/overlay-common/etc/diosix/charter.toml",
        MAX_MANIFEST_SIZE,
    );
    defer unmapBinaryFile(shipped_charter);
    const parsed = try charter.parseCharterToml(shipped_charter);
    try testing.expectEqualStrings("autonomous-mesh-01", parsed.id());
    try testing.expectEqual(@as(u16, 2), parsed.quorum_required);
    try testing.expectEqual(@as(u16, 3), parsed.quorum_total);
    try testing.expectEqual(@as(u16, 3), parsed.min_stewards);

    const shipped_sys = try readBinaryFile(
        "tools/overlay-common/etc/diosix/diosix.toml",
        65536,
    );
    defer unmapBinaryFile(shipped_sys);
    const sys_parsed = sysconfig.parseSystemConfigToml(shipped_sys);
    try testing.expectEqual(@as(usize, 1), sys_parsed.default_vcpus);
    try testing.expectEqualStrings("256 MB", sys_parsed.defaultRam());
    try testing.expectEqual(@as(usize, 5), sys_parsed.tour_count);

    const shipped_install = try readBinaryFile(
        "tools/overlay-common/etc/diosix/install.toml",
        65536,
    );
    defer unmapBinaryFile(shipped_install);
    const inst_parsed = installer.parseInstallConfigToml(shipped_install);
    try testing.expectEqual(@as(usize, 512), inst_parsed.boot_part_mb);
    try testing.expectEqual(@as(usize, 4096), inst_parsed.state_part_mb);
}

test "Command enum dispatches all CLI commands and aliases" {
    const Command = main.Command;
    try testing.expectEqual(
        Command.host,
        std.meta.stringToEnum(Command, "host").?,
    );
    try testing.expectEqual(
        Command.run,
        std.meta.stringToEnum(Command, "run").?,
    );
    try testing.expectEqual(
        Command.create,
        std.meta.stringToEnum(Command, "create").?,
    );
    try testing.expectEqual(
        Command.@"install-guest",
        std.meta.stringToEnum(Command, "install-guest").?,
    );
    try testing.expectEqual(
        Command.list,
        std.meta.stringToEnum(Command, "list").?,
    );
    try testing.expectEqual(
        Command.ps,
        std.meta.stringToEnum(Command, "ps").?,
    );
    try testing.expectEqual(
        Command.ssh,
        std.meta.stringToEnum(Command, "ssh").?,
    );
    try testing.expectEqual(
        Command.charter,
        std.meta.stringToEnum(Command, "charter").?,
    );
    try testing.expectEqual(
        Command.steward,
        std.meta.stringToEnum(Command, "steward").?,
    );
    try testing.expectEqual(
        Command.@"drop-trust",
        std.meta.stringToEnum(Command, "drop-trust").?,
    );
    try testing.expect(
        std.meta.stringToEnum(Command, "nonexistent-cmd") == null,
    );
}

test "setExeName and getExeName store and strip path prefixes" {
    try testing.expectEqualStrings("dsx", common.getExeName());
    common.setExeName("/usr/bin/diosix-ctl");
    try testing.expectEqualStrings("diosix-ctl", common.getExeName());
    common.setExeName("dsx");
    try testing.expectEqualStrings("dsx", common.getExeName());
}
