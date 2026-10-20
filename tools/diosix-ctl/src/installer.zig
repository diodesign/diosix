// Diosix Persistent Host Installer Engine (`dsx host install`).
//
// Supports Basic Guided Mode (3-step wizard: Target Disk -> Passkey ->
// Partition & Install) and Expert Declarative Mode (`--config
// diosix-install.toml`) with A/B boot slot layout, strict device path
// validation, and JSON output for Operator Agents.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const console = @import("console.zig");
const sysconfig = @import("sysconfig.zig");

pub const INSTALL_RECEIPT_PATH = sysconfig.INSTALL_RECEIPT_PATH;
pub const DEFAULT_BOOT_PART_MB: usize = 256;
pub const DEFAULT_STATE_PART_MB: usize = 512;

pub const InstallMode = enum {
    basic,
    expert,

    pub fn label(self: InstallMode) []const u8 {
        return switch (self) {
            .basic => "basic",
            .expert => "expert",
        };
    }

    pub fn fromStr(s: []const u8) ?InstallMode {
        const ModeAlias = enum { basic, guided, expert, declarative };
        const parsed = std.meta.stringToEnum(ModeAlias, s) orelse return null;
        return switch (parsed) {
            .basic, .guided => .basic,
            .expert, .declarative => .expert,
        };
    }
};

pub const InstallPlan = struct {
    mode: InstallMode = .basic,
    target_disk: []const u8 = sysconfig.DEFAULT_TARGET_DISK,
    hostname: []const u8 = "diosix-host",
    seat_profile: []const u8 = "desktop-kbd",
    boot_part_mb: usize = DEFAULT_BOOT_PART_MB,
    state_part_mb: usize = DEFAULT_STATE_PART_MB,
    active_slot: []const u8 = "slot_a",
    standby_slot: []const u8 = "slot_b",
    enable_stewards: bool = false,
    standby_root_vm: bool = false,
    passkey_enrolled: bool = true,
    dry_run: bool = false,
};

fn trimAscii(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

fn unquoteTomlValue(raw: []const u8) []const u8 {
    const trimmed = trimAscii(raw);
    if (trimmed.len >= 2 and
        trimmed[0] == '"' and
        trimmed[trimmed.len - 1] == '"')
    {
        return trimmed[1 .. trimmed.len - 1];
    }
    return trimmed;
}

/// Validates that a block device or disk image path is safe (starts with
/// `/dev/`, `/tmp/`, or `/var/lib/diosix/`, contains no `..`, whitespace, or
/// shell metacharacters).
pub fn isValidBlockDevicePath(path: []const u8) bool {
    if (path.len < 6 or path.len > 128) return false;
    if (!std.mem.startsWith(u8, path, sysconfig.DEV_DIR_PREFIX) and
        !std.mem.startsWith(u8, path, "/tmp/") and
        !std.mem.startsWith(u8, path, sysconfig.VAR_LIB_DIOSIX_PREFIX))
    {
        return false;
    }
    if (std.mem.indexOf(u8, path, "..") != null) return false;
    for (path) |ch| {
        const ok = std.ascii.isAlphanumeric(ch) or
            ch == '/' or ch == '-' or ch == '_' or ch == '.';
        if (!ok) return false;
    }
    return true;
}

/// Validates that a hostname contains only RFC-1123 alphanumeric, hyphen, or
/// dot characters.
pub fn isValidHostname(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    if (name[0] == '-' or
        name[0] == '.' or
        name[name.len - 1] == '-' or
        name[name.len - 1] == '.')
    {
        return false;
    }
    for (name) |ch| {
        const ok = std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '.';
        if (!ok) return false;
    }
    return true;
}

/// Parses a declarative `diosix-install.toml` configuration into an
/// `InstallPlan`.
pub fn parseInstallConfigToml(content: []const u8) InstallPlan {
    const ConfigKey = enum {
        mode,
        target_disk,
        disk,
        hostname,
        seat_profile,
        seat,
        boot_part_mb,
        state_part_mb,
        enable_stewards,
        standby_root,
        standby_root_vm,
    };

    var plan = InstallPlan{ .mode = .expert };
    var line_it = std.mem.splitScalar(u8, content, '\n');
    while (line_it.next()) |raw_line| {
        const line = trimAscii(raw_line);
        if (line.len == 0 or line[0] == '#' or line[0] == '[') continue;
        if (std.mem.indexOfScalar(u8, line, '=')) |eq_idx| {
            const key = trimAscii(line[0..eq_idx]);
            const val = unquoteTomlValue(line[eq_idx + 1 ..]);
            if (std.meta.stringToEnum(ConfigKey, key)) |k| {
                switch (k) {
                    .mode => if (InstallMode.fromStr(val)) |m| {
                        plan.mode = m;
                    },
                    .target_disk, .disk => if (isValidBlockDevicePath(val)) {
                        plan.target_disk = val;
                    },
                    .hostname => if (isValidHostname(val)) {
                        plan.hostname = val;
                    },
                    .seat_profile, .seat => if (isValidHostname(val)) {
                        plan.seat_profile = val;
                    },
                    .boot_part_mb => {
                        const parsed = std.fmt.parseInt(
                            usize,
                            val,
                            10,
                        ) catch DEFAULT_BOOT_PART_MB;
                        plan.boot_part_mb = std.math.clamp(parsed, 64, 16384);
                    },
                    .state_part_mb => {
                        const parsed = std.fmt.parseInt(
                            usize,
                            val,
                            10,
                        ) catch DEFAULT_STATE_PART_MB;
                        plan.state_part_mb = std.math.clamp(parsed, 64, 65536);
                    },
                    .enable_stewards => {
                        plan.enable_stewards = std.mem.eql(u8, val, "true");
                    },
                    .standby_root, .standby_root_vm => {
                        plan.standby_root_vm = std.mem.eql(u8, val, "true");
                    },
                }
            }
        }
    }
    return plan;
}

/// Formats the `/var/lib/diosix/install-receipt.toml` manifest for a completed
/// host installation. The caller owns the returned slice.
pub fn allocInstallReceiptToml(
    allocator: std.mem.Allocator,
    plan: InstallPlan,
) ![]u8 {
    return allocator.print(
        \\# Diosix Host Installation Receipt
        \\[install]
        \\mode = "{s}"
        \\target_disk = "{s}"
        \\hostname = "{s}"
        \\seat_profile = "{s}"
        \\boot_part_mb = {d}
        \\state_part_mb = {d}
        \\active_slot = "{s}"
        \\standby_slot = "{s}"
        \\enable_stewards = {s}
        \\standby_root_vm = {s}
        \\
    ,
        .{
            plan.mode.label(),
            plan.target_disk,
            plan.hostname,
            plan.seat_profile,
            plan.boot_part_mb,
            plan.state_part_mb,
            plan.active_slot,
            plan.standby_slot,
            if (plan.enable_stewards) "true" else "false",
            if (plan.standby_root_vm) "true" else "false",
        },
    );
}

/// Formats the human-readable or JSON output for `dsx host install`. The
/// caller owns the returned slice.
pub fn allocInstallPlanOutput(
    allocator: std.mem.Allocator,
    plan: InstallPlan,
    json_mode: bool,
) ![]u8 {
    const p_sep: []const u8 =
        if (std.mem.indexOf(u8, plan.target_disk, "nvme") != null or
        std.mem.indexOf(u8, plan.target_disk, "mmcblk") != null)
            "p"
        else
            "";
    if (json_mode) {
        const json_fmt =
            "{{\"status\":\"{s}\",\"mode\":\"{s}\",\"target_disk\":\"{s}\"," ++
            "\"hostname\":\"{s}\",\"seat_profile\":\"{s}\"," ++
            "\"partitions\":[" ++
            "{{\"label\":\"DIOSIX_BOOT\",\"dev\":\"{s}{s}1\"," ++
            "\"size_mb\":{d},\"slots\":[\"{s}\",\"{s}\"]}}," ++
            "{{\"label\":\"DIOSIX_STATE\",\"dev\":\"{s}{s}2\"," ++
            "\"size_mb\":{d}}}," ++
            "{{\"label\":\"DIOSIX_DATA\",\"dev\":\"{s}{s}3\"," ++
            "\"size_mb\":\"remaining\"}}]," ++
            "\"enable_stewards\":{s},\"standby_root_vm\":{s}}}\n";
        return allocator.print(
            json_fmt,
            .{
                if (plan.dry_run) "dry_run" else "installed",
                plan.mode.label(),
                plan.target_disk,
                plan.hostname,
                plan.seat_profile,
                plan.target_disk,
                p_sep,
                plan.boot_part_mb,
                plan.active_slot,
                plan.standby_slot,
                plan.target_disk,
                p_sep,
                plan.state_part_mb,
                plan.target_disk,
                p_sep,
                if (plan.enable_stewards) "true" else "false",
                if (plan.standby_root_vm) "true" else "false",
            },
        );
    }

    const steward_str = if (plan.enable_stewards)
        "enabled (Root -> Stewards -> Leafs)"
    else
        "optional (Root -> Leafs default)";
    const standby_str = if (plan.standby_root_vm)
        "enabled (warm failover replica)"
    else
        "disabled";
    const status_str = if (plan.dry_run)
        "✓ Dry-run complete (no block devices modified)."
    else
        "✓ Persistent host installation layout staged " ++
            "(/var/lib/diosix/install-receipt.toml).";

    const text_fmt =
        "Diosix host installer ({s} mode)\n" ++
        "  Target disk      : {s}\n" ++
        "  Hostname         : {s}\n" ++
        "  Seat profile     : {s}\n" ++
        "  GPT partition 1  : {s}{s}1 (DIOSIX_BOOT, {d} MB, " ++
        "A/B slots: {s} + {s})\n" ++
        "  GPT partition 2  : {s}{s}2 (DIOSIX_STATE, {d} MB, " ++
        "passkeys & charter)\n" ++
        "  GPT partition 3  : {s}{s}3 (DIOSIX_DATA, remaining capacity, " ++
        "VM images & disks)\n" ++
        "  Steward tier     : {s}\n" ++
        "  Standby Root VM  : {s}\n" ++
        "{s}\n";

    return allocator.print(
        text_fmt,
        .{
            plan.mode.label(),
            plan.target_disk,
            plan.hostname,
            plan.seat_profile,
            plan.target_disk,
            p_sep,
            plan.boot_part_mb,
            plan.active_slot,
            plan.standby_slot,
            plan.target_disk,
            p_sep,
            plan.state_part_mb,
            plan.target_disk,
            p_sep,
            steward_str,
            standby_str,
            status_str,
        },
    );
}

// -----------------------------------------------------------------------------
// Unit Tests
// -----------------------------------------------------------------------------
const testing = std.testing;

test "isValidBlockDevicePath accepts valid devices and rejects bad paths" {
    testing.refAllDecls(@This());
    try testing.expect(isValidBlockDevicePath("/dev/vda"));
    try testing.expect(isValidBlockDevicePath("/dev/nvme0n1"));
    try testing.expect(isValidBlockDevicePath("/dev/mmcblk0"));
    try testing.expect(!isValidBlockDevicePath("/dev/../etc/passwd"));
    try testing.expect(!isValidBlockDevicePath("/dev/vda;rm -rf /"));
    try testing.expect(!isValidBlockDevicePath("relative/disk"));
}

test "parseInstallConfigToml and formatInstallPlanOutput support modes" {
    const sample_toml =
        \\[install]
        \\mode = "expert"
        \\target_disk = "/dev/nvme0n1"
        \\hostname = "cluster-node-01"
        \\seat_profile = "headless-serial"
        \\boot_part_mb = 512
        \\state_part_mb = 1024
        \\enable_stewards = true
        \\standby_root_vm = true
    ;
    const plan = parseInstallConfigToml(sample_toml);
    try testing.expectEqual(InstallMode.expert, plan.mode);
    try testing.expectEqualStrings("/dev/nvme0n1", plan.target_disk);
    try testing.expectEqualStrings("cluster-node-01", plan.hostname);
    try testing.expectEqualStrings("headless-serial", plan.seat_profile);
    try testing.expectEqual(@as(usize, 512), plan.boot_part_mb);
    try testing.expectEqual(@as(usize, 1024), plan.state_part_mb);
    try testing.expect(plan.enable_stewards);
    try testing.expect(plan.standby_root_vm);

    const json_out = try allocInstallPlanOutput(testing.allocator, plan, true);
    defer testing.allocator.free(json_out);
    try testing.expect(
        std.mem.indexOf(u8, json_out, "\"dev\":\"/dev/nvme0n1p1\"") != null,
    );
    try testing.expect(
        std.mem.indexOf(u8, json_out, "\"enable_stewards\":true") != null,
    );

    const text_out = try allocInstallPlanOutput(testing.allocator, plan, false);
    defer testing.allocator.free(text_out);
    try testing.expect(
        std.mem.indexOf(
            u8,
            text_out,
            "/dev/nvme0n1p1 (DIOSIX_BOOT, 512 MB",
        ) != null,
    );

    const receipt = try allocInstallReceiptToml(testing.allocator, plan);
    defer testing.allocator.free(receipt);
    try testing.expect(
        std.mem.indexOf(u8, receipt, "boot_part_mb = 512") != null,
    );
}
