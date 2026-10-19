// Diosix Runtime System & CLI Configuration Parser (/etc/diosix/diosix.toml).
//
// Separates implementation mechanisms from user- and maintainer-tunable policy
// defaults: default VM vCPUs/RAM/disk/subnet, repository directory paths,
// configuration file locations, and interactive Guided Tour steps.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const common = @import("common.zig");
const tour = @import("sysconfig/tour.zig");

pub const DEFAULT_SYSCONFIG_PATH = "/etc/diosix/diosix.toml";
pub const DEFAULT_IMAGES_DIR = "/var/lib/diosix/images";
pub const DEFAULT_ISO_DIR = "/var/lib/diosix/iso";
pub const DEFAULT_DISKS_DIR = "/var/lib/diosix/disks";
pub const DEFAULT_SNAPSHOTS_DIR = "/var/lib/diosix/snapshots";
pub const DEFAULT_KEYS_DIR = "/var/lib/diosix/keys";
pub const MAX_TOUR_STEPS = tour.MAX_TOUR_STEPS;
pub const TourStep = tour.TourStep;
pub const Config = SystemConfig;

const setBuf = common.setFixedBuf;

pub const SystemConfig = struct {
    // [vm_defaults].
    default_vcpus: usize = 1,
    default_ram_buf: [32]u8 = @splat(0),
    default_ram_len: usize = 0,
    default_disk_mb: usize = 1024,
    install_default_disk_mb: usize = 4096,
    default_arch_buf: [16]u8 = @splat(0),
    default_arch_len: usize = 0,
    subnet_prefix_buf: [32]u8 = @splat(0),
    subnet_prefix_len: usize = 0,

    // [paths] / [storage].
    images_dir_buf: [128]u8 = @splat(0),
    images_dir_len: usize = 0,
    iso_dir_buf: [128]u8 = @splat(0),
    iso_dir_len: usize = 0,
    disks_dir_buf: [128]u8 = @splat(0),
    disks_dir_len: usize = 0,
    snapshots_dir_buf: [128]u8 = @splat(0),
    snapshots_dir_len: usize = 0,
    keys_dir_buf: [128]u8 = @splat(0),
    keys_dir_len: usize = 0,
    system_manifest_buf: [128]u8 = @splat(0),
    system_manifest_len: usize = 0,
    catalog_config_buf: [128]u8 = @splat(0),
    catalog_config_len: usize = 0,
    charter_config_buf: [128]u8 = @splat(0),
    charter_config_len: usize = 0,
    constitution_doc_buf: [128]u8 = @splat(0),
    constitution_doc_len: usize = 0,
    install_config_buf: [128]u8 = @splat(0),
    install_config_len: usize = 0,

    // [[tour]].
    tour_steps: [MAX_TOUR_STEPS]TourStep = @splat(.{}),
    tour_count: usize = 0,

    pub fn initDefaults() SystemConfig {
        var cfg = SystemConfig{};
        setBuf(&cfg.default_ram_buf, &cfg.default_ram_len, "256 MB");
        setBuf(&cfg.default_arch_buf, &cfg.default_arch_len, "riscv64");
        setBuf(&cfg.subnet_prefix_buf, &cfg.subnet_prefix_len, "10.0.3.");
        setBuf(&cfg.images_dir_buf, &cfg.images_dir_len, DEFAULT_IMAGES_DIR);
        setBuf(&cfg.iso_dir_buf, &cfg.iso_dir_len, DEFAULT_ISO_DIR);
        setBuf(&cfg.disks_dir_buf, &cfg.disks_dir_len, DEFAULT_DISKS_DIR);
        setBuf(
            &cfg.snapshots_dir_buf,
            &cfg.snapshots_dir_len,
            DEFAULT_SNAPSHOTS_DIR,
        );
        setBuf(&cfg.keys_dir_buf, &cfg.keys_dir_len, DEFAULT_KEYS_DIR);
        setBuf(
            &cfg.system_manifest_buf,
            &cfg.system_manifest_len,
            "/etc/diosix/system.toml",
        );
        setBuf(
            &cfg.catalog_config_buf,
            &cfg.catalog_config_len,
            "/etc/diosix/catalog.toml",
        );
        setBuf(
            &cfg.charter_config_buf,
            &cfg.charter_config_len,
            "/etc/diosix/charter.toml",
        );
        setBuf(
            &cfg.constitution_doc_buf,
            &cfg.constitution_doc_len,
            "/etc/diosix/constitution.md",
        );
        setBuf(
            &cfg.install_config_buf,
            &cfg.install_config_len,
            "/etc/diosix/install.toml",
        );

        cfg.tour_count = tour.initDefaultTourSteps(&cfg.tour_steps);
        return cfg;
    }

    pub fn defaultRam(self: *const SystemConfig) []const u8 {
        return self.default_ram_buf[0..self.default_ram_len];
    }

    pub fn defaultArch(self: *const SystemConfig) []const u8 {
        return self.default_arch_buf[0..self.default_arch_len];
    }

    pub fn subnetPrefix(self: *const SystemConfig) []const u8 {
        return self.subnet_prefix_buf[0..self.subnet_prefix_len];
    }

    pub fn imagesDir(self: *const SystemConfig) []const u8 {
        return self.images_dir_buf[0..self.images_dir_len];
    }

    pub fn isoDir(self: *const SystemConfig) []const u8 {
        return self.iso_dir_buf[0..self.iso_dir_len];
    }

    pub fn disksDir(self: *const SystemConfig) []const u8 {
        return self.disks_dir_buf[0..self.disks_dir_len];
    }

    pub fn snapshotsDir(self: *const SystemConfig) []const u8 {
        return self.snapshots_dir_buf[0..self.snapshots_dir_len];
    }

    pub fn keysDir(self: *const SystemConfig) []const u8 {
        return self.keys_dir_buf[0..self.keys_dir_len];
    }

    pub fn systemManifestPath(self: *const SystemConfig) []const u8 {
        return self.system_manifest_buf[0..self.system_manifest_len];
    }

    pub fn catalogConfigPath(self: *const SystemConfig) []const u8 {
        return self.catalog_config_buf[0..self.catalog_config_len];
    }

    pub fn charterConfigPath(self: *const SystemConfig) []const u8 {
        return self.charter_config_buf[0..self.charter_config_len];
    }

    pub fn constitutionDocPath(self: *const SystemConfig) []const u8 {
        return self.constitution_doc_buf[0..self.constitution_doc_len];
    }

    pub fn installConfigPath(self: *const SystemConfig) []const u8 {
        return self.install_config_buf[0..self.install_config_len];
    }
};

/// Parses `/etc/diosix/diosix.toml` content into a `SystemConfig`, falling back
/// to safe defaults for any omitted keys.
pub fn parseSystemConfigToml(content: []const u8) SystemConfig {
    var cfg = SystemConfig.initDefaults();
    var has_custom_tour = false;

    const Section = enum {
        none,
        vm_defaults,
        paths,
        storage,
        tour,
    };
    var section: Section = .none;
    var active_tour_idx: ?usize = null;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = common.trimAscii(raw_line);
        if (line.len == 0 or line[0] == '#') continue;

        if (std.mem.eql(u8, line, "[[tour]]")) {
            section = .tour;
            if (!has_custom_tour) {
                has_custom_tour = true;
                cfg.tour_count = 0;
            }
            if (cfg.tour_count < MAX_TOUR_STEPS) {
                active_tour_idx = cfg.tour_count;
                cfg.tour_steps[cfg.tour_count] = .{};
                cfg.tour_count += 1;
            } else {
                active_tour_idx = null;
            }
            continue;
        }

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
                            setBuf(
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
                            setBuf(
                                &cfg.default_arch_buf,
                                &cfg.default_arch_len,
                                val,
                            );
                        },
                        .subnet_prefix => if (val.len > 0) {
                            setBuf(
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
                            .images_dir => setBuf(
                                &cfg.images_dir_buf,
                                &cfg.images_dir_len,
                                val,
                            ),
                            .iso_dir => setBuf(
                                &cfg.iso_dir_buf,
                                &cfg.iso_dir_len,
                                val,
                            ),
                            .disks_dir => setBuf(
                                &cfg.disks_dir_buf,
                                &cfg.disks_dir_len,
                                val,
                            ),
                            .snapshots_dir => setBuf(
                                &cfg.snapshots_dir_buf,
                                &cfg.snapshots_dir_len,
                                val,
                            ),
                            .keys_dir => setBuf(
                                &cfg.keys_dir_buf,
                                &cfg.keys_dir_len,
                                val,
                            ),
                            .system_manifest => setBuf(
                                &cfg.system_manifest_buf,
                                &cfg.system_manifest_len,
                                val,
                            ),
                            .catalog_config => setBuf(
                                &cfg.catalog_config_buf,
                                &cfg.catalog_config_len,
                                val,
                            ),
                            .charter_config => setBuf(
                                &cfg.charter_config_buf,
                                &cfg.charter_config_len,
                                val,
                            ),
                            .constitution_doc => setBuf(
                                &cfg.constitution_doc_buf,
                                &cfg.constitution_doc_len,
                                val,
                            ),
                            .install_config => setBuf(
                                &cfg.install_config_buf,
                                &cfg.install_config_len,
                                val,
                            ),
                        }
                    }
                }
            },
            .tour => {
                const TourKey = enum { title, summary, cli_hint };
                if (active_tour_idx) |idx| {
                    var step = &cfg.tour_steps[idx];
                    if (std.meta.stringToEnum(TourKey, key)) |k| {
                        switch (k) {
                            .title => step.setTitle(val),
                            .summary => step.setSummary(val),
                            .cli_hint => step.setHint(val),
                        }
                    }
                }
            },
        }
    }

    return cfg;
}

test "parseSystemConfigToml parses vm_defaults, paths, and tour steps" {
    std.testing.refAllDecls(@This());
    _ = tour;
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
        \\
        \\[[tour]]
        \\title = "Custom Step 1"
        \\summary = "Custom tour summary"
        \\cli_hint = "dsx host info"
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
    try testing.expectEqual(@as(usize, 1), cfg.tour_count);
    try testing.expectEqualStrings("Custom Step 1", cfg.tour_steps[0].title());
    try testing.expectEqualStrings(
        "Custom tour summary",
        cfg.tour_steps[0].summary(),
    );
    try testing.expectEqualStrings(
        "dsx host info",
        cfg.tour_steps[0].cliHint(),
    );
}
