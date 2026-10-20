// Diosix Hypervisor Guest Management CLI — Formatting & Command Unit Tests.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const testing = std.testing;
const main = @import("../main.zig");
const api = main.api;
const charter = main.charter;
const sysconfig = main.sysconfig;
const common = main.common;
const loader = main.loader;
const ssh = main.ssh;
const installer = main.installer;
const vm = main.vm;
const host = main.host;
const governance = main.governance;

const MAX_MANIFEST_SIZE = common.MAX_MANIFEST_SIZE;
const readBinaryFile = common.readBinaryFile;
const unmapBinaryFile = common.unmapBinaryFile;
const formatSelfInfo = vm.formatSelfInfo;
const formatVersionChannel = host.formatVersionChannel;
const formatHostInfo = host.formatHostInfo;

const TEST_SHORT_BUF_LEN: usize = 32;
const TEST_SELF_BUF_LEN: usize = 512;
const TEST_HOST_BUF_LEN: usize = 1024;
const TEST_TOML_MAX_SIZE: usize = 65536;

test "formatVersionChannel CalVer formatting" {
    var buf: [TEST_SHORT_BUF_LEN]u8 = undefined;
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

    var text_buf: [TEST_SELF_BUF_LEN]u8 = undefined;
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

    var json_buf: [TEST_SELF_BUF_LEN]u8 = undefined;
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

    var text_buf: [TEST_HOST_BUF_LEN]u8 = undefined;
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

    var json_buf: [TEST_HOST_BUF_LEN]u8 = undefined;
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

test "loader canonical paths and SHIM_HEADER_MAGIC are configured" {
    try testing.expectEqualStrings(
        sysconfig.GUEST_SHIM_PATH,
        loader.GUEST_SHIM_PATH,
    );
    try testing.expectEqualStrings(
        sysconfig.DEFAULT_GUEST_IMAGE_PATH,
        loader.DEFAULT_GUEST_IMAGE_PATH,
    );
    try testing.expectEqualStrings(
        sysconfig.FALLBACK_GUEST_IMAGE_PATH,
        loader.FALLBACK_GUEST_IMAGE_PATH,
    );
    try testing.expectEqualStrings(
        sysconfig.FALLBACK_GUEST_ISO_PATH,
        loader.FALLBACK_GUEST_ISO_PATH,
    );
    try testing.expectEqual(
        @as(u64, 0x4d49_4853_5853_4f44),
        loader.SHIM_HEADER_MAGIC,
    );
}

test "parseProposalAction and shipped TOML configs parse cleanly" {
    for ([_]struct { []const u8, charter.ProposalAction }{
        .{ "amend-charter", .amend_charter },
        .{ "retire-steward", .terminate_steward },
        .{ "reset-steward", .reset_steward },
        .{ "promote-standby-root", .root_failover },
        .{ "terminate-vm", .terminate_units },
    }) |pair| {
        try testing.expectEqual(
            pair[1],
            governance.parseProposalAction(pair[0]).?,
        );
    }
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
        TEST_TOML_MAX_SIZE,
    );
    defer unmapBinaryFile(shipped_sys);
    const sys_parsed = sysconfig.parseSystemConfigToml(shipped_sys);
    try testing.expectEqual(@as(usize, 1), sys_parsed.default_vcpus);
    try testing.expectEqualStrings("256 MB", sys_parsed.defaultRam());
    try testing.expectEqual(@as(usize, 5), sys_parsed.tour_count);

    const shipped_install = try readBinaryFile(
        "tools/overlay-common/etc/diosix/install.toml",
        TEST_TOML_MAX_SIZE,
    );
    defer unmapBinaryFile(shipped_install);
    const inst_parsed = installer.parseInstallConfigToml(shipped_install);
    try testing.expectEqual(@as(usize, 256), inst_parsed.boot_part_mb);
    try testing.expectEqual(@as(usize, 512), inst_parsed.state_part_mb);
}

test "Command enum dispatches all CLI commands and aliases" {
    const Command = main.Command;
    for ([_]struct { []const u8, Command }{
        .{ "host", .host },
        .{ "run", .run },
        .{ "create", .create },
        .{ "install-guest", .@"install-guest" },
        .{ "list", .list },
        .{ "ps", .ps },
        .{ "ssh", .ssh },
        .{ "charter", .charter },
        .{ "steward", .steward },
        .{ "drop-trust", .@"drop-trust" },
    }) |pair| {
        try testing.expectEqual(
            pair[1],
            std.meta.stringToEnum(Command, pair[0]).?,
        );
    }
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

test "security validators enforce strict path and SSH argument bounds" {
    const disks_dir = sysconfig.DEFAULT_DISKS_DIR;
    try testing.expect(
        common.isSafeStoragePath("/var/lib/diosix/disks/a.img", disks_dir),
    );
    try testing.expect(common.isSafeStoragePath("/tmp/test.img", disks_dir));
    try testing.expect(
        !common.isSafeStoragePath(
            "/var/lib/diosix/disks-evil/a.img",
            disks_dir,
        ),
    );
    try testing.expect(
        !common.isSafeStoragePath("/tmp-evil/a.img", disks_dir),
    );
    try testing.expect(
        !common.isSafeStoragePath("/var/lib/diosix/disks", disks_dir),
    );

    try testing.expect(ssh.isValidSshUsername("root"));
    try testing.expect(!ssh.isValidSshUsername("-oProxyCommand=id"));
    try testing.expect(ssh.isValidSshIp("10.0.3.2"));
    try testing.expect(!ssh.isValidSshIp("-oLocalCommand=id"));

    testing.refAllDecls(@This());
}
