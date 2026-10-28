// Canonical Filesystem, Device, and IPC Paths for Diosix GUI.
//
// Centralizes all external device nodes, runtime state files, and system
// configuration paths used by diosix-gui so mechanism modules remain free of
// scattered path literals.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

/// Hypervisor kernel character device node in the Root VM.
pub const DEV_DIOSIX_PATH: [*:0]const u8 = "/dev/diosix";

/// Kernel uptime procfs node.
pub const PROC_UPTIME_PATH: [*:0]const u8 = "/proc/uptime";

/// Kernel command-line procfs node.
pub const PROC_CMDLINE_PATH: [*:0]const u8 = "/proc/cmdline";

/// Kernel CPU statistics procfs node.
pub const PROC_STAT_PATH: [*:0]const u8 = "/proc/stat";

/// Kernel memory statistics procfs node.
pub const PROC_MEMINFO_PATH: [*:0]const u8 = "/proc/meminfo";

/// Kernel mounted filesystems procfs node.
pub const PROC_MOUNTS_PATH: [*:0]const u8 = "/proc/mounts";

/// Kernel block partitions procfs node.
pub const PROC_PARTITIONS_PATH: [*:0]const u8 = "/proc/partitions";

/// Kernel hostname procfs node.
pub const PROC_HOSTNAME_PATH: [*:0]const u8 = "/proc/sys/kernel/hostname";

/// System reboot binary fallback path.
pub const REBOOT_BIN_PATH: [*:0]const u8 = "/sbin/reboot";

/// System poweroff binary fallback path.
pub const POWEROFF_BIN_PATH: [*:0]const u8 = "/sbin/poweroff";

/// Candidate dsx CLI binary paths for child guest lifecycle management.
pub const DSX_BIN_PATHS = [_][*:0]const u8{
    "/usr/bin/dsx",
    "/bin/dsx",
    "/usr/sbin/dsx",
};

/// ALSA/OSS mixer initialization helper binary path.
pub const ALSA_INIT_BIN_PATH: [*:0]const u8 = "/usr/sbin/diosix-alsa-init";

/// Candidate OSS/ALSA DSP device nodes probed by the intro audio worker.
pub const DSP_DEVICE_PATHS = [_][*:0]const u8{
    "/dev/dsp",
    "/dev/dsp0",
    "/dev/sound/dsp",
};

/// Candidate DRM/KMS scanout card device nodes probed at display startup.
pub const DRI_CARD_PATHS = [_][]const u8{
    "/dev/dri/card0",
    "/dev/dri/card1",
};

/// Legacy fbdev scanout device node fallback.
pub const FB0_DEVICE_PATH: [*:0]const u8 = "/dev/fb0";

/// Evdev input device node prefix (`/dev/input/event0` .. `event31`).
pub const INPUT_EVENT_PATH_PREFIX: []const u8 = "/dev/input/event";

/// Root-owned runtime directory for Diosix IPC, locks, and boot sentinels.
pub const RUN_DIOSIX_DIR: [*:0]const u8 = "/run/diosix";

/// Runtime guest registry TOML path written by dsx.
pub const GUEST_REGISTRY_PATH: [*:0]const u8 = "/run/diosix/guests.toml";

/// Persistent and shared guest VM image and storage directories.
pub const VAR_IMAGES_DIR: [*:0]const u8 = "/var/lib/diosix/images";
pub const SHARE_IMAGES_DIR: [*:0]const u8 = "/usr/share/diosix/images";
pub const VAR_DISKS_DIR: [*:0]const u8 = "/var/lib/diosix/disks";
pub const VAR_ISO_DIR: [*:0]const u8 = "/var/lib/diosix/iso";

/// Singleton flock path preventing concurrent diosix-gui instances.
pub const GUI_LOCK_PATH: [*:0]const u8 = "/run/diosix/diosix-gui.lock";

/// Semantic IPC command intake path written by `dsx gui`.
pub const GUI_CMD_PATH: [*:0]const u8 = "/run/diosix/gui_cmd";

/// Semantic GUI state JSON export path read by `dsx gui status`.
pub const GUI_STATE_PATH: [*:0]const u8 = "/run/diosix/gui_state.json";

/// Temporary staging file for atomic GUI state JSON updates.
pub const GUI_STATE_TMP_PATH: [*:0]const u8 = "/run/diosix/gui_state.json.tmp";

/// Sentinel file recording that the once-per-boot intro animation has played.
pub const INTRO_FLAG_PATH: [*:0]const u8 = "/run/diosix/intro_played";

/// Default system configuration TOML path.
pub const DEFAULT_SYSCONFIG_PATH: [*:0]const u8 = "/etc/diosix/diosix.toml";

/// Pseudo-terminal master multiplexer device node.
pub const DEV_PTMX_PATH: [*:0]const u8 = "/dev/ptmx";

/// Pseudo-terminal slave path format string.
pub const DEV_PTS_FMT: []const u8 = "/dev/pts/{d}";

/// Local Root VM shell binary path.
pub const SHELL_BIN_PATH: [*:0]const u8 = "/bin/sh";

test "paths: canonical paths are non-empty and rooted" {
    std.testing.refAllDecls(@This());
    try std.testing.expectEqual('/', std.mem.span(DEV_DIOSIX_PATH)[0]);
    try std.testing.expectEqual('/', std.mem.span(RUN_DIOSIX_DIR)[0]);
    try std.testing.expectEqual('/', std.mem.span(GUI_STATE_PATH)[0]);
    try std.testing.expect(DRI_CARD_PATHS.len >= 1);
    try std.testing.expect(DSP_DEVICE_PATHS.len >= 1);
}
