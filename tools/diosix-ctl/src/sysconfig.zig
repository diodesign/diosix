// Diosix Runtime System & CLI Configuration (/etc/diosix/diosix.toml).
//
// Separates implementation mechanisms from user- and maintainer-tunable policy
// defaults: default VM vCPUs/RAM/disk/subnet, repository directory paths,
// configuration file locations, system binaries, and Guided Tour steps.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const common = @import("common.zig");
const tour = @import("sysconfig/tour.zig");
const parser = @import("sysconfig/parser.zig");

pub const DEFAULT_SYSCONFIG_PATH = "/etc/diosix/diosix.toml";
pub const DEFAULT_DEVICE_PATH = "/dev/diosix";

// Ephemeral runtime state paths (/run/diosix).
pub const RUN_DIOSIX_DIR = "/run/diosix";
pub const GUEST_REGISTRY_PATH = "/run/diosix/guests.toml";
pub const GUI_CMD_PATH = "/run/diosix/gui_cmd";
pub const GUI_STATE_PATH = "/run/diosix/gui_state.json";
pub const CHARTER_SECRETS_DIR = "/run/diosix/charter";
pub const STEWARD_CONSENSUS_PATH = "/run/diosix/steward_consensus";
pub const AUTH_PENDING_PATH = "/run/diosix/auth.pending";
pub const CHALLENGE_STATE_PATH = "/run/diosix/auth_challenge.state";
pub const TOUCH_SEAT_PATH = "/run/diosix/touch_seat";
pub const DISK_STAGING_PREFIX = "/run/diosix/staging";

// System configuration paths (/etc/diosix & /etc).
pub const AUTH_ENROLLED_PATH = "/etc/diosix/auth.enrolled";
pub const NETWORK_INTERFACES_PATH = "/etc/network/interfaces";
pub const DEFAULT_SYSTEM_MANIFEST_PATH = "/etc/diosix/system.toml";
pub const DEFAULT_LOCAL_MANIFEST_PATH = "/etc/diosix/manifest.toml";
pub const DEFAULT_CATALOG_CONFIG_PATH = "/etc/diosix/catalog.toml";
pub const DEFAULT_CHARTER_CONFIG_PATH = "/etc/diosix/charter.toml";
pub const DEFAULT_CONSTITUTION_DOC_PATH = "/etc/diosix/constitution.md";
pub const DEFAULT_INSTALL_CONFIG_PATH = "/etc/diosix/install.toml";
pub const ETC_MANAGEMENT_PRIVKEY_PATH = "/etc/diosix/management_ed25519";
pub const ETC_MANAGEMENT_PUBKEY_PATH = "/etc/diosix/management_ed25519.pub";

// Persistent storage & state paths (/var/lib/diosix).
pub const VAR_LIB_DIOSIX_DIR = "/var/lib/diosix";
pub const VAR_LIB_DIOSIX_PREFIX = "/var/lib/diosix/";
pub const DEFAULT_IMAGES_DIR = "/var/lib/diosix/images";
pub const DEFAULT_ISO_DIR = "/var/lib/diosix/iso";
pub const DEFAULT_DISKS_DIR = "/var/lib/diosix/disks";
pub const DEFAULT_SNAPSHOTS_DIR = "/var/lib/diosix/snapshots";
pub const DEFAULT_KEYS_DIR = "/var/lib/diosix/keys";
pub const ACTIVE_CHARTER_STATE_PATH = "/var/lib/diosix/charter/active.toml";
pub const CHARTER_AUDIT_LOG_PATH = "/var/lib/diosix/charter/audit.log";
pub const WHISPER_SPOOL_PATH = "/var/lib/diosix/charter/whispers.log";
pub const INSTALL_RECEIPT_PATH = "/var/lib/diosix/install.receipt";
pub const AUTHORIZED_PASSKEYS_PATH =
    "/var/lib/diosix/keys/authorized_passkeys";
pub const DEV_AUTHORIZED_KEYS_PATH = "/var/lib/diosix/keys/authorized_keys";
pub const DEFAULT_SCREENSHOT_PATH = "/var/lib/diosix/screenshot.bmp";

// Root SSH key paths.
pub const ROOT_SSH_DIR = "/root/.ssh";
pub const ROOT_AUTHORIZED_KEYS_PATH = "/root/.ssh/authorized_keys";

// Boot, shim, and default guest image paths.
pub const GUEST_SHIM_DIR = "/usr/share/diosix";
pub const GUEST_SHIM_PATH = "/usr/share/diosix/guest-shim.bin";
pub const GUEST_SHIM_PATHS = [_][]const u8{
    "/boot/guest-shim.bin",
    "/usr/share/diosix/guest-shim.bin",
    "zig-out/bin/guest-shim.bin",
};
pub const STEWARD_DEFAULT_KERNELS = [_][]const u8{
    "/var/lib/diosix/images/steward-kernel.bin",
    "/boot/Image",
};
pub const DEFAULT_GUEST_IMAGE_PATH =
    "/var/lib/diosix/images/diosix-base-linux.elf";
pub const LINUX_GUEST_IMAGE_PATH = "/var/lib/diosix/images/Image";
pub const FALLBACK_GUEST_IMAGE_PATH = "/boot/guest-default.bin";
pub const FALLBACK_GUEST_ISO_PATH = "/boot/guest-default.iso";
pub const BOOT_KERNEL_IMAGE_PATHS = [_][]const u8{
    "/boot/Image",
    "/var/lib/diosix/images/Image",
};
pub const BOOT_INITRD_PATHS = [_][]const u8{
    "/boot/initramfs.cpio.gz",
    "/boot/rootfs.cpio.gz",
};
pub const BOOT_SCRIPT_PATHS = [_][]const u8{
    "/boot/boot.scr",
    "/var/lib/diosix/boot.scr",
};

// Kernel, procfs, sysfs, and device nodes.
pub const SYS_FIRMWARE_FDT_PATH = "/sys/firmware/fdt";
pub const PROC_CMDLINE_PATH = "/proc/cmdline";
pub const DEV_NULL_PATH = "/dev/null";
pub const DEV_URANDOM_PATH = "/dev/urandom";
pub const DEV_DRI_CARD0_PATH = "/dev/dri/card0";
pub const DEV_TOUCHSCREEN0_PATH = "/dev/input/touchscreen0";
pub const DEV_FB0_PATH = "/dev/fb0";
pub const DEV_HIDRAW0_PATH = "/dev/hidraw0";
pub const DEV_HIDRAW1_PATH = "/dev/hidraw1";
pub const DEV_TPMRM0_PATH = "/dev/tpmrm0";
pub const DEV_TPM0_PATH = "/dev/tpm0";
pub const DEFAULT_TARGET_DISK = "/dev/vda";
pub const CANDIDATE_HOST_DISKS = [_][]const u8{
    "/dev/nvme0n1",
    "/dev/vdb",
    "/dev/vda",
    "/dev/sda",
};
pub const TMP_DIR_PREFIX = "/tmp";
pub const DEV_DIR_PREFIX = "/dev/";

// System utility binary search paths and canonical tool paths.
pub const SYSTEM_BIN_SEARCH_PATHS = [_][]const u8{
    "/usr/sbin",
    "/usr/bin",
    "/sbin",
    "/bin",
};
pub const MKFS_EXT4_BIN = "/sbin/mkfs.ext4";
pub const MKFS_VFAT_BIN = "/sbin/mkfs.vfat";
pub const SFDISK_BIN = "/sbin/sfdisk";
pub const BLKID_BIN = "/sbin/blkid";
pub const LOSETUP_BIN = "/sbin/losetup";
pub const RESIZE2FS_BIN = "/sbin/resize2fs";
pub const MOUNT_BIN = "/bin/mount";
pub const UMOUNT_BIN = "/bin/umount";
pub const CP_BIN = "/bin/cp";
pub const IP_BIN = "/sbin/ip";
pub const BRCTL_BIN = "/usr/sbin/brctl";
pub const SSH_BIN = "/usr/bin/ssh";
pub const SSH_CLIENT_BINS = [_][]const u8{
    "/usr/bin/ssh",
    "/usr/bin/dbclient",
    "/bin/ssh",
};
pub const NC_BIN = "/usr/bin/nc";
pub const WGET_BIN = "/usr/bin/wget";
pub const CURL_BIN = "/usr/bin/curl";

pub const MAX_TOUR_STEPS = tour.MAX_TOUR_STEPS;
pub const TourStep = tour.TourStep;
pub const Config = SystemConfig;
pub const parseSystemConfigToml = parser.parseSystemConfigToml;

const setBuf = common.setFixedBuf;

/// Capacity for short scalar settings such as "256 MB" or "10.0.3.".
const SHORT_VALUE_MAX: usize = 32;
/// Capacity for an architecture name such as "riscv64".
const ARCH_NAME_MAX: usize = 16;
/// Capacity for a configured directory or file path. `SystemConfig` is passed
/// by value, so this is a deliberate policy limit rather than PATH_MAX.
const CONFIG_PATH_MAX: usize = 128;

/// Stores a parsed config value, or warns and keeps the existing value when it
/// does not fit, so an over-long path is never silently truncated.
pub fn setChecked(dest: []u8, len_out: *usize, val: []const u8) void {
    if (val.len > dest.len) {
        common.printFmt(
            "Warning: ignoring config value '{s}' (longer than {d} bytes).\n",
            .{ val, dest.len },
        );
        return;
    }
    setBuf(dest, len_out, val);
}

pub const SystemConfig = struct {
    // [vm_defaults].
    default_vcpus: usize = 1,
    default_ram_buf: [SHORT_VALUE_MAX]u8 = @splat(0),
    default_ram_len: usize = 0,
    default_disk_mb: usize = 1024,
    install_default_disk_mb: usize = 4096,
    default_arch_buf: [ARCH_NAME_MAX]u8 = @splat(0),
    default_arch_len: usize = 0,
    subnet_prefix_buf: [SHORT_VALUE_MAX]u8 = @splat(0),
    subnet_prefix_len: usize = 0,

    // [paths] / [storage].
    images_dir_buf: [CONFIG_PATH_MAX]u8 = @splat(0),
    images_dir_len: usize = 0,
    iso_dir_buf: [CONFIG_PATH_MAX]u8 = @splat(0),
    iso_dir_len: usize = 0,
    disks_dir_buf: [CONFIG_PATH_MAX]u8 = @splat(0),
    disks_dir_len: usize = 0,
    snapshots_dir_buf: [CONFIG_PATH_MAX]u8 = @splat(0),
    snapshots_dir_len: usize = 0,
    keys_dir_buf: [CONFIG_PATH_MAX]u8 = @splat(0),
    keys_dir_len: usize = 0,
    system_manifest_buf: [CONFIG_PATH_MAX]u8 = @splat(0),
    system_manifest_len: usize = 0,
    catalog_config_buf: [CONFIG_PATH_MAX]u8 = @splat(0),
    catalog_config_len: usize = 0,
    charter_config_buf: [CONFIG_PATH_MAX]u8 = @splat(0),
    charter_config_len: usize = 0,
    constitution_doc_buf: [CONFIG_PATH_MAX]u8 = @splat(0),
    constitution_doc_len: usize = 0,
    install_config_buf: [CONFIG_PATH_MAX]u8 = @splat(0),
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
            DEFAULT_SYSTEM_MANIFEST_PATH,
        );
        setBuf(
            &cfg.catalog_config_buf,
            &cfg.catalog_config_len,
            DEFAULT_CATALOG_CONFIG_PATH,
        );
        setBuf(
            &cfg.charter_config_buf,
            &cfg.charter_config_len,
            DEFAULT_CHARTER_CONFIG_PATH,
        );
        setBuf(
            &cfg.constitution_doc_buf,
            &cfg.constitution_doc_len,
            DEFAULT_CONSTITUTION_DOC_PATH,
        );
        setBuf(
            &cfg.install_config_buf,
            &cfg.install_config_len,
            DEFAULT_INSTALL_CONFIG_PATH,
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

test "sysconfig: defaults and parser re-exports" {
    std.testing.refAllDecls(@This());
    _ = tour;
    _ = parser;
    const cfg = SystemConfig.initDefaults();
    try std.testing.expectEqual(@as(usize, 1), cfg.default_vcpus);
    try std.testing.expectEqualStrings("256 MB", cfg.defaultRam());
    try std.testing.expectEqualStrings(
        DEFAULT_SYSTEM_MANIFEST_PATH,
        cfg.systemManifestPath(),
    );
    try std.testing.expectEqual(@as(usize, 5), cfg.tour_count);
    try std.testing.expectEqualStrings(
        "1. Root VM & Hardware Partitioning",
        cfg.tour_steps[0].title(),
    );
}
