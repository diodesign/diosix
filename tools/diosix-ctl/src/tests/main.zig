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
const parseCid = common.parseCid;
const isArch = common.isArch;
const parseMemorySizeMb = common.parseMemorySizeMb;
const readBinaryFile = common.readBinaryFile;
const unmapBinaryFile = common.unmapBinaryFile;
const matchTarget = common.matchTarget;

const TEST_SHORT_BUF_LEN: usize = 32;
const TEST_VERSION_MAX_SIZE: usize = 1024;
const TEST_MISSING_MAX_SIZE: usize = 4096;

test {
    inline for (.{
        @This(),
        api,
        manifest,
        catalog,
        passkey,
        installer,
        charter,
        sysconfig,
        common,
        loader,
        ssh,
        storage,
        vm,
        host,
        governance,
        @import("../auth.zig"),
        @import("../auth/enroll.zig"),
        @import("../catalog/format.zig"),
        @import("../console.zig"),
        @import("../charter/cmd.zig"),
        @import("../charter/status.zig"),
        @import("../charter/toml.zig"),
        @import("../charter/whisper.zig"),
        @import("../common/output.zig"),
        @import("../gui.zig"),
        @import("../host/info.zig"),
        @import("../image.zig"),
        @import("../image/import.zig"),
        @import("../image/pull.zig"),
        @import("../loader/pe.zig"),
        @import("../manifest/cmd.zig"),
        @import("../manifest/lexer.zig"),
        @import("../manifest/policy.zig"),
        @import("../registry.zig"),
        @import("../snapshot.zig"),
        @import("../ssh/sync.zig"),
        @import("../storage/disk.zig"),
        @import("../sysconfig/parser.zig"),
        @import("../sysconfig/tour.zig"),
        @import("../vm/fdt_patch.zig"),
        @import("../vm/info.zig"),
        @import("../vm/install.zig"),
        @import("../vm/owned.zig"),
        @import("../vm/restart.zig"),
        @import("../vm/run.zig"),
        @import("../vm/stage.zig"),
        @import("../whisper.zig"),
        @import("cli.zig"),
    }) |mod| testing.refAllDecls(mod);
    testing.refAllDecls(@This());
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
        readBinaryFile(
            "/nonexistent/file/path/here.bin",
            TEST_MISSING_MAX_SIZE,
        ),
    );

    const content = try readBinaryFile("VERSION", TEST_VERSION_MAX_SIZE);
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
    var buf1: [TEST_SHORT_BUF_LEN]u8 = undefined;
    var buf2: [TEST_SHORT_BUF_LEN]u8 = undefined;
    var buf3: [TEST_SHORT_BUF_LEN]u8 = undefined;

    const s1 = try std.fmt.bufPrint(
        &buf1,
        "{d} MB",
        .{parseMemorySizeMb("256M")},
    );
    const s2 = try std.fmt.bufPrint(
        &buf2,
        "{d} MB",
        .{parseMemorySizeMb("512 MB")},
    );
    const s3 = try std.fmt.bufPrint(
        &buf3,
        "{d} MB",
        .{parseMemorySizeMb("2GiB")},
    );

    try testing.expectEqualStrings("256 MB", s1);
    try testing.expectEqualStrings("512 MB", s2);
    try testing.expectEqualStrings("2048 MB", s3);
}

test "disk path and capacity resolution" {
    var path_buf: [MAX_PATH_LEN]u8 = undefined;
    const disk_name = "user-data";
    const full_path = try std.fmt.bufPrint(
        &path_buf,
        "{s}/{s}.img",
        .{ sysconfig.DEFAULT_DISKS_DIR, disk_name },
    );
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
    const snap_path = try std.fmt.bufPrint(
        &snap_buf,
        "{s}/{s}_{s}.snap",
        .{ sysconfig.DEFAULT_SNAPSHOTS_DIR, "leenix", "checkpoint-1" },
    );
    try testing.expectEqualStrings(
        "/var/lib/diosix/snapshots/leenix_checkpoint-1.snap",
        snap_path,
    );
}

test "image and cdrom path resolution" {
    var iso_buf: [MAX_PATH_LEN]u8 = undefined;
    const iso_name = "debian-12-netinst";
    const full_iso_path = try std.fmt.bufPrint(
        &iso_buf,
        "{s}/{s}.iso",
        .{ sysconfig.DEFAULT_ISO_DIR, iso_name },
    );
    try testing.expectEqualStrings(
        "/var/lib/diosix/iso/debian-12-netinst.iso",
        full_iso_path,
    );

    var img_buf: [MAX_PATH_LEN]u8 = undefined;
    const img_name = "debian-installer";
    const full_img_path = try std.fmt.bufPrint(
        &img_buf,
        "{s}/{s}.elf",
        .{ sysconfig.DEFAULT_IMAGES_DIR, img_name },
    );
    try testing.expectEqualStrings(
        "/var/lib/diosix/images/debian-installer.elf",
        full_img_path,
    );
}
