// Unit Tests for Diosix Hypervisor Manifest Parser & Attenuation Engine.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const testing = std.testing;
const manifest = @import("../manifest.zig");

const parseSystemManifest = manifest.parseSystemManifest;
const parseChildManifest = manifest.parseChildManifest;
const pruneSystemManifest = manifest.pruneSystemManifest;
const serializeChildManifest = manifest.serializeChildManifest;
const resolveService = manifest.resolveService;
const ManifestLexer = manifest.ManifestLexer;

test "manifest: TOML parsing and capability attenuation roundtrip" {
    const allocator = testing.allocator;

    const sample_system_toml =
        \\# System bootstrap manifest
        \\[system]
        \\version = "1.0"
        \\domain = "diosix.local"
        \\
        \\[domains.sys]
        \\name = "sys-supervisor"
        \\image = "/boot/sys-supervisor.elf"
        \\harts = [0, 1]
        \\ram = "2GiB"
        \\grant_devices = ["0000:00:01.0", "0000:00:02.0"]
        \\can_provide = ["net.*", "gui.*", "fs.*"]
        \\provides = [
        \\  { service = "net.wan", channel = "shmem", type = "ethernet" },
        \\  { service = "gui.wayland", channel = "vsock", type = "display" }
        \\]
        \\
        \\[domains.user]
        \\name = "user-domain"
        \\image = "/var/lib/diosix/images/diosix-linux.elf"
        \\vcpus = 4
        \\ram = "14GiB"
        \\can_require = ["net.*", "gui.*", "fs.*"]
        \\routes = [
        \\  { require = "net.wan", resolve_to = "sys.net.wan" },
        \\  { require = "gui.display", resolve_to = "sys.gui.wayland" }
        \\]
    ;

    var sys = try parseSystemManifest(allocator, sample_system_toml);
    defer sys.deinit();

    try testing.expectEqualStrings("1.0", sys.version);
    try testing.expectEqualStrings("diosix.local", sys.domain);
    try testing.expect(sys.domains.contains("sys"));
    try testing.expect(sys.domains.contains("user"));

    const sys_dom = sys.domains.get("sys").?;
    try testing.expectEqual(@as(usize, 2), sys_dom.vcpus);
    try testing.expectEqualStrings("2GiB", sys_dom.ram);
    try testing.expectEqual(@as(usize, 2), sys_dom.provides.items.len);
    try testing.expectEqualStrings(
        "net.wan",
        sys_dom.provides.items[0].service,
    );

    const user_dom = sys.domains.get("user").?;
    try testing.expectEqual(@as(usize, 4), user_dom.vcpus);
    try testing.expectEqual(@as(usize, 2), user_dom.routes.items.len);

    // Map domain names to CIDs.
    var cid_map = std.StringHashMap(usize).init(allocator);
    defer cid_map.deinit();
    try cid_map.put("sys", 2);
    try cid_map.put("user", 3);

    // Prune for user domain (CID 3).
    var child_user = try pruneSystemManifest(
        allocator,
        &sys,
        "user",
        3,
        1,
        &cid_map,
    );
    defer child_user.deinit();

    try testing.expectEqualStrings("user-domain", child_user.name);
    try testing.expectEqual(@as(usize, 3), child_user.cid);
    try testing.expectEqual(@as(usize, 1), child_user.parent_cid);
    try testing.expectEqual(@as(usize, 2), child_user.required.items.len);

    // Verify service routing.
    const gui_req = resolveService(&child_user, "gui.display").?;
    try testing.expectEqualStrings("gui.wayland", gui_req.as_alias);
    try testing.expectEqual(@as(usize, 2), gui_req.target_cid);
    try testing.expectEqualStrings("sys", gui_req.target_domain);

    // Test serialization.
    const serialized = try serializeChildManifest(allocator, &child_user);
    defer allocator.free(serialized);

    try testing.expect(std.mem.indexOf(u8, serialized, "[vm]") != null);
    try testing.expect(
        std.mem.indexOf(u8, serialized, "name = \"user-domain\"") != null,
    );
    try testing.expect(
        std.mem.indexOf(u8, serialized, "target_cid = 2") != null,
    );

    // Parse back serialized child manifest.
    var parsed_child = try parseChildManifest(allocator, serialized);
    defer parsed_child.deinit();

    try testing.expectEqualStrings("user-domain", parsed_child.name);
    try testing.expectEqual(@as(usize, 3), parsed_child.cid);
    try testing.expectEqual(@as(usize, 2), parsed_child.required.items.len);
}

test "manifest: private IP address parsing and attenuation propagation" {
    const allocator = testing.allocator;

    const sample_toml =
        \\[system]
        \\version = "1.0"
        \\domain = "diosix.local"
        \\
        \\[domains.user]
        \\name = "user-domain"
        \\image = "/var/lib/diosix/images/diosix-linux.elf"
        \\vcpus = 2
        \\ram = "256MB"
        \\ip = "10.0.3.3"
    ;

    var sys = try parseSystemManifest(allocator, sample_toml);
    defer sys.deinit();

    const user_dom = sys.domains.get("user").?;
    try testing.expectEqualStrings("10.0.3.3", user_dom.ip);

    var child = try pruneSystemManifest(allocator, &sys, "user", 2, 1, null);
    defer child.deinit();

    try testing.expectEqualStrings("10.0.3.3", child.ip);

    const serialized = try serializeChildManifest(allocator, &child);
    defer allocator.free(serialized);

    try testing.expect(
        std.mem.indexOf(u8, serialized, "ip = \"10.0.3.3\"") != null,
    );

    var parsed = try parseChildManifest(allocator, serialized);
    defer parsed.deinit();

    try testing.expectEqualStrings("user-domain", parsed.name);
    try testing.expectEqualStrings("10.0.3.3", parsed.ip);
}

test "manifest: domain storage and disk attenuation propagation" {
    const allocator = testing.allocator;

    const sample_toml =
        \\[system]
        \\version = "1.0"
        \\domain = "diosix.local"
        \\
        \\[domains.user]
        \\name = "user-domain"
        \\image = "/var/lib/diosix/images/diosix-linux.elf"
        \\vcpus = 2
        \\ram = "512MB"
        \\disk = "/var/lib/diosix/disks/user.img"
        \\storage_size = "4GiB"
        \\ip = "10.0.3.5"
    ;

    var sys = try parseSystemManifest(allocator, sample_toml);
    defer sys.deinit();

    const user_dom = sys.domains.get("user").?;
    try testing.expectEqualStrings(
        "/var/lib/diosix/disks/user.img",
        user_dom.disk,
    );
    try testing.expectEqualStrings("4GiB", user_dom.storage_size);

    var child = try pruneSystemManifest(allocator, &sys, "user", 2, 1, null);
    defer child.deinit();

    try testing.expectEqualStrings(
        "/var/lib/diosix/disks/user.img",
        child.disk,
    );
    try testing.expectEqualStrings("4GiB", child.storage_size);

    const serialized = try serializeChildManifest(allocator, &child);
    defer allocator.free(serialized);

    try testing.expect(
        std.mem.indexOf(
            u8,
            serialized,
            "disk = \"/var/lib/diosix/disks/user.img\"",
        ) != null,
    );
    try testing.expect(
        std.mem.indexOf(u8, serialized, "storage_size = \"4GiB\"") != null,
    );

    var parsed = try parseChildManifest(allocator, serialized);
    defer parsed.deinit();

    try testing.expectEqualStrings(
        "/var/lib/diosix/disks/user.img",
        parsed.disk,
    );
    try testing.expectEqualStrings("4GiB", parsed.storage_size);
}

test "manifest: domain cdrom attenuation propagation" {
    const allocator = testing.allocator;

    const sample_toml =
        \\[system]
        \\version = "1.0"
        \\domain = "diosix.local"
        \\
        \\[domains.installer]
        \\name = "installer-domain"
        \\image = "/var/lib/diosix/images/debian-installer.elf"
        \\vcpus = 2
        \\ram = "1GiB"
        \\disk = "/var/lib/diosix/disks/target.img"
        \\cdrom = "/var/lib/diosix/iso/debian-12.iso"
        \\ip = "10.0.3.9"
    ;

    var sys = try parseSystemManifest(allocator, sample_toml);
    defer sys.deinit();

    const inst_dom = sys.domains.get("installer").?;
    try testing.expectEqualStrings(
        "/var/lib/diosix/disks/target.img",
        inst_dom.disk,
    );
    try testing.expectEqualStrings(
        "/var/lib/diosix/iso/debian-12.iso",
        inst_dom.cdrom,
    );

    var child = try pruneSystemManifest(
        allocator,
        &sys,
        "installer",
        2,
        1,
        null,
    );
    defer child.deinit();

    try testing.expectEqualStrings(
        "/var/lib/diosix/iso/debian-12.iso",
        child.cdrom,
    );

    const serialized = try serializeChildManifest(allocator, &child);
    defer allocator.free(serialized);

    try testing.expect(
        std.mem.indexOf(
            u8,
            serialized,
            "cdrom = \"/var/lib/diosix/iso/debian-12.iso\"",
        ) != null,
    );

    var parsed = try parseChildManifest(allocator, serialized);
    defer parsed.deinit();

    try testing.expectEqualStrings(
        "/var/lib/diosix/iso/debian-12.iso",
        parsed.cdrom,
    );
}

test "manifest: ManifestLexer terminates on unexpected special characters" {
    const allocator = testing.allocator;
    const noisy_toml =
        \\[system]
        \\version = "1.0" ; @ $ % * ? ! ~
        \\[domains.user]
        \\name = "user-domain"
        \\vcpus = 2
    ;
    var lexer = ManifestLexer.init(noisy_toml);
    var steps: usize = 0;
    while (steps < 256) : (steps += 1) {
        const tok = lexer.next();
        if (tok.tag == .eof) break;
    }
    try testing.expect(steps < 256);

    var sys = try parseSystemManifest(allocator, noisy_toml);
    defer sys.deinit();
    try testing.expect(sys.domains.contains("user"));
    testing.refAllDecls(@This());
}
