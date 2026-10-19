// Diosix Runtime System & CLI Configuration Parser (/etc/diosix/diosix.toml).
//
// Separates implementation mechanisms from user- and maintainer-tunable policy
// defaults: default VM vCPUs/RAM/disk/subnet, repository directory paths,
// configuration file locations, and interactive Guided Tour steps.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub const DEFAULT_SYSCONFIG_PATH = "/etc/diosix/diosix.toml";
pub const MAX_TOUR_STEPS: usize = 8;

pub const TourStep = struct {
    title_buf: [96]u8 = @splat(0),
    title_len: usize = 0,
    summary_buf: [256]u8 = @splat(0),
    summary_len: usize = 0,
    hint_buf: [128]u8 = @splat(0),
    hint_len: usize = 0,

    pub fn set(
        self: *TourStep,
        t: []const u8,
        s: []const u8,
        h: []const u8,
    ) void {
        self.setTitle(t);
        self.setSummary(s);
        self.setHint(h);
    }

    pub fn setTitle(self: *TourStep, s: []const u8) void {
        const n = @min(s.len, self.title_buf.len);
        @memcpy(self.title_buf[0..n], s[0..n]);
        self.title_len = n;
    }

    pub fn setSummary(self: *TourStep, s: []const u8) void {
        const n = @min(s.len, self.summary_buf.len);
        @memcpy(self.summary_buf[0..n], s[0..n]);
        self.summary_len = n;
    }

    pub fn setHint(self: *TourStep, s: []const u8) void {
        const n = @min(s.len, self.hint_buf.len);
        @memcpy(self.hint_buf[0..n], s[0..n]);
        self.hint_len = n;
    }

    pub fn title(self: *const TourStep) []const u8 {
        return self.title_buf[0..self.title_len];
    }

    pub fn summary(self: *const TourStep) []const u8 {
        return self.summary_buf[0..self.summary_len];
    }

    pub fn cliHint(self: *const TourStep) []const u8 {
        return self.hint_buf[0..self.hint_len];
    }
};

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

    // [paths].
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

        cfg.tour_steps[0].set(
            "Step 1/5: Root VM & Hardware Trust",
            "The Root VM (CID 1) orchestrates hardware drivers, storage " ++
                "volumes, and child VM lifecycles via M-mode SBI hypercalls.",
            "dsx host info && dsx info",
        );
        cfg.tour_steps[1].set(
            "Step 2/5: Virtual Machine Fleet & Isolation",
            "Child VMs run in isolated Stage-2 memory partitions with " ++
                "private point-to-point networking and zero upward SSH access.",
            "dsx image catalog && dsx image list",
        );
        cfg.tour_steps[2].set(
            "Step 3/5: Passkey & Zero-Password Security",
            "All password logins are disabled. Operators authenticate via " ++
                "FIDO2 USB/NFC keys, TPM 2.0 platform passkeys, QR pairing, " ++
                "or UART challenge-response.",
            "dsx auth status && dsx auth list",
        );
        cfg.tour_steps[3].set(
            "Step 4/5: Autonomic Steward Collective",
            "Tier-1 Steward VMs enforce the sealed M-mode Constitutional " ++
                "Charter via M-of-N quorum ratification and Standby Root " ++
                "failover.",
            "dsx charter status && dsx charter audit",
        );
        cfg.tour_steps[4].set(
            "Step 5/5: Bare-Metal Host Installation",
            "Install the immutable Diosix boot image and persistent " ++
                "storage partition onto physical NVMe or VirtIO disks.",
            "dsx host install --mode basic --dry-run",
        );
        cfg.tour_count = 5;
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

fn setBuf(buf: []u8, len_out: *usize, val: []const u8) void {
    const n = @min(val.len, buf.len);
    @memcpy(buf[0..n], val[0..n]);
    len_out.* = n;
}

fn unquote(raw: []const u8) []const u8 {
    var s = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.indexOfScalar(u8, s, '#')) |c_idx| {
        if (s.len == 0 or s[0] != '"') {
            s = std.mem.trim(u8, s[0..c_idx], " \t\r\n");
        } else if (std.mem.indexOfScalarPos(u8, s, 1, '"')) |close_q| {
            if (c_idx > close_q) {
                s = std.mem.trim(u8, s[0..c_idx], " \t\r\n");
            }
        }
    }
    if (s.len >= 2 and
        ((s[0] == '"' and s[s.len - 1] == '"') or
            (s[0] == '\'' and s[s.len - 1] == '\'')))
    {
        return s[1 .. s.len - 1];
    }
    return s;
}

/// Parses `/etc/diosix/diosix.toml` content into a `SystemConfig`, falling back
/// to safe defaults for any omitted keys.
pub fn parseSystemConfigToml(content: []const u8) SystemConfig {
    var cfg = SystemConfig.initDefaults();
    var has_custom_tour = false;

    const Section = enum {
        none,
        vm_defaults,
        paths,
        tour,
    };
    var section: Section = .none;
    var active_tour_idx: ?usize = null;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
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
            const hdr = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
            section = std.meta.stringToEnum(Section, hdr) orelse .none;
            continue;
        }

        const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq_idx], " \t");
        const val = unquote(line[eq_idx + 1 ..]);

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
            .paths => {
                const PathKey = enum {
                    system_manifest,
                    catalog_config,
                    charter_config,
                    constitution_doc,
                    install_config,
                };
                if (val.len > 0) {
                    if (std.meta.stringToEnum(PathKey, key)) |k| {
                        switch (k) {
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
