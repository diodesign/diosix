// Diosix Runtime System Configuration TOML Parser (/etc/diosix/diosix.toml).
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const common = @import("../common.zig");
const sysconfig = @import("../sysconfig.zig");

const SystemConfig = sysconfig.SystemConfig;
const setChecked = sysconfig.setChecked;

/// Parses `/etc/diosix/diosix.toml` content into a `SystemConfig`, falling back
/// to safe defaults for any omitted keys.
pub fn parseSystemConfigToml(content: []const u8) SystemConfig {
    var cfg = SystemConfig.initDefaults();

    const Section = enum {
        none,
        vm_defaults,
        paths,
        storage,
    };
    var section: Section = .none;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = common.trimAscii(raw_line);
        if (line.len == 0 or line[0] == '#') continue;

        if (line[0] == '[' and line[line.len - 1] == ']') {
            const hdr = common.trimAscii(line[1 .. line.len - 1]);
            section = std.meta.stringToEnum(Section, hdr) orelse .none;
            continue;
        }

        const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = common.trimAscii(line[0..eq_idx]);
        const val = common.unquoteToml(line[eq_idx + 1 ..]);

        switch (section) {
            .vm_defaults, .none => {
                const VmDefaultKey = enum {
                    default_vcpus,
                    default_ram,
                    default_disk_mb,
                    install_default_disk_mb,
                    default_arch,
                    subnet_prefix,
                };
                if (std.meta.stringToEnum(VmDefaultKey, key)) |k| {
                    switch (k) {
                        .default_vcpus => {
                            const n =
                                std.fmt.parseInt(usize, val, 10) catch 1;
                            cfg.default_vcpus = @max(1, @min(n, 64));
                        },
                        .default_ram => if (val.len > 0) {
                            setChecked(
                                &cfg.default_ram_buf,
                                &cfg.default_ram_len,
                                val,
                            );
                        },
                        .default_disk_mb => {
                            const n =
                                std.fmt.parseInt(usize, val, 10) catch 1024;
                            cfg.default_disk_mb =
                                @max(64, @min(n, 1024 * 1024));
                        },
                        .install_default_disk_mb => {
                            const n =
                                std.fmt.parseInt(usize, val, 10) catch 4096;
                            cfg.install_default_disk_mb =
                                @max(128, @min(n, 1024 * 1024));
                        },
                        .default_arch => if (val.len > 0) {
                            setChecked(
                                &cfg.default_arch_buf,
                                &cfg.default_arch_len,
                                val,
                            );
                        },
                        .subnet_prefix => if (val.len > 0) {
                            setChecked(
                                &cfg.subnet_prefix_buf,
                                &cfg.subnet_prefix_len,
                                val,
                            );
                        },
                    }
                }
            },
            .paths, .storage => {
                const PathKey = enum {
                    images_dir,
                    iso_dir,
                    disks_dir,
                    snapshots_dir,
                    keys_dir,
                    system_manifest,
                    catalog_config,
                    charter_config,
                    constitution_doc,
                    install_config,
                };
                if (val.len > 0) {
                    if (std.meta.stringToEnum(PathKey, key)) |k| {
                        switch (k) {
                            .images_dir => setChecked(
                                &cfg.images_dir_buf,
                                &cfg.images_dir_len,
                                val,
                            ),
                            .iso_dir => setChecked(
                                &cfg.iso_dir_buf,
                                &cfg.iso_dir_len,
                                val,
                            ),
                            .disks_dir => setChecked(
                                &cfg.disks_dir_buf,
                                &cfg.disks_dir_len,
                                val,
                            ),
                            .snapshots_dir => setChecked(
                                &cfg.snapshots_dir_buf,
                                &cfg.snapshots_dir_len,
                                val,
                            ),
                            .keys_dir => setChecked(
                                &cfg.keys_dir_buf,
                                &cfg.keys_dir_len,
                                val,
                            ),
                            .system_manifest => setChecked(
                                &cfg.system_manifest_buf,
                                &cfg.system_manifest_len,
                                val,
                            ),
                            .catalog_config => setChecked(
                                &cfg.catalog_config_buf,
                                &cfg.catalog_config_len,
                                val,
                            ),
                            .charter_config => setChecked(
                                &cfg.charter_config_buf,
                                &cfg.charter_config_len,
                                val,
                            ),
                            .constitution_doc => setChecked(
                                &cfg.constitution_doc_buf,
                                &cfg.constitution_doc_len,
                                val,
                            ),
                            .install_config => setChecked(
                                &cfg.install_config_buf,
                                &cfg.install_config_len,
                                val,
                            ),
                        }
                    }
                }
            },
        }
    }

    return cfg;
}

test "sysconfig/parser: parses vm_defaults and paths" {
    std.testing.refAllDecls(@This());
    const testing = std.testing;
    const sample =
        \\[vm_defaults]
        \\default_vcpus = 2
        \\default_ram = "512 MB"
        \\default_disk_mb = 2048
        \\install_default_disk_mb = 8192
        \\default_arch = "riscv64"
        \\subnet_prefix = "10.0.9."
        \\
        \\[paths]
        \\images_dir = "/custom/images"
        \\iso_dir = "/custom/iso"
        \\disks_dir = "/custom/disks"
        \\snapshots_dir = "/custom/snapshots"
        \\keys_dir = "/custom/keys"
        \\catalog_config = "/etc/diosix/custom-catalog.toml"
        \\charter_config = "/etc/diosix/custom-charter.toml"
    ;

    const cfg = parseSystemConfigToml(sample);
    try testing.expectEqual(@as(usize, 2), cfg.default_vcpus);
    try testing.expectEqualStrings("512 MB", cfg.defaultRam());
    try testing.expectEqual(@as(usize, 2048), cfg.default_disk_mb);
    try testing.expectEqual(@as(usize, 8192), cfg.install_default_disk_mb);
    try testing.expectEqualStrings("10.0.9.", cfg.subnetPrefix());
    try testing.expectEqualStrings("/custom/images", cfg.imagesDir());
    try testing.expectEqualStrings("/custom/iso", cfg.isoDir());
    try testing.expectEqualStrings("/custom/disks", cfg.disksDir());
    try testing.expectEqualStrings("/custom/snapshots", cfg.snapshotsDir());
    try testing.expectEqualStrings("/custom/keys", cfg.keysDir());
    try testing.expectEqualStrings(
        "/etc/diosix/custom-catalog.toml",
        cfg.catalogConfigPath(),
    );
    try testing.expectEqualStrings(
        "/etc/diosix/custom-charter.toml",
        cfg.charterConfigPath(),
    );
}
