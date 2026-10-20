// Diosix Interactive Guided Tour Step Definitions & Defaults.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const common = @import("../common.zig");

pub const MAX_TOUR_STEPS: usize = 8;
/// Display capacities for one tour step: a one-line title, a short summary
/// paragraph, and a single CLI command hint.
pub const TOUR_TITLE_MAX: usize = 96;
pub const TOUR_SUMMARY_MAX: usize = 256;
pub const TOUR_HINT_MAX: usize = 128;

/// Copies `s` into a tour field, warning when it had to be truncated.
fn setTourField(dest: []u8, len_out: *usize, s: []const u8) void {
    if (s.len > dest.len) {
        common.printFmt(
            "Warning: tour text truncated to {d} bytes: '{s}'\n",
            .{ dest.len, s },
        );
    }
    common.setFixedBuf(dest, len_out, s);
}

pub const TourStep = struct {
    title_buf: [TOUR_TITLE_MAX]u8 = @splat(0),
    title_len: usize = 0,
    summary_buf: [TOUR_SUMMARY_MAX]u8 = @splat(0),
    summary_len: usize = 0,
    hint_buf: [TOUR_HINT_MAX]u8 = @splat(0),
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
        setTourField(&self.title_buf, &self.title_len, s);
    }

    pub fn setSummary(self: *TourStep, s: []const u8) void {
        setTourField(&self.summary_buf, &self.summary_len, s);
    }

    pub fn setHint(self: *TourStep, s: []const u8) void {
        setTourField(&self.hint_buf, &self.hint_len, s);
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

pub fn initDefaultTourSteps(steps: *[MAX_TOUR_STEPS]TourStep) usize {
    steps[0].set(
        "1. Root VM & Hardware Partitioning",
        "You are inside the Root VM (VM 0). It manages hardware drivers, " ++
            "storage, and networking while the M-mode hypervisor enforces " ++
            "strict PMP/Stage-2 memory isolation.",
        "dsx host info",
    );
    steps[1].set(
        "2. Zero-Configuration VM Quickstart",
        "Launch isolated Linux or bare-metal Guest VMs with automatic " ++
            "kernel staging, VirtIO block/network attachment, and DHCP IP " ++
            "assignment.",
        "dsx run alpine",
    );
    steps[2].set(
        "3. Declarative Fleet & Storage Management",
        "Create persistent virtual disks, capture instant VM memory/disk " ++
            "snapshots, and orchestrate multi-VM topologies from " ++
            "/etc/diosix/system.toml.",
        "dsx disk list && dsx snapshot list",
    );
    steps[3].set(
        "4. Constitutional AI Steward Governance",
        "Inspect the immutable M-mode Constitutional Charter, Tier-1 " ++
            "Steward consensus quorum, and real-time Whisper telemetry bus.",
        "dsx charter status",
    );
    steps[4].set(
        "5. Zero-Password Passkey Authentication",
        "Diosix eliminates password logins. Enroll FIDO2 hardware keys, " ++
            "TPM 2.0 platform passkeys, or QR-paired mobile authenticators.",
        "dsx auth status",
    );
    return 5;
}

test "sysconfig/tour: initializes default 5-step guided tour" {
    std.testing.refAllDecls(@This());
    var steps: [MAX_TOUR_STEPS]TourStep = @splat(.{});
    const count = initDefaultTourSteps(&steps);
    try std.testing.expectEqual(@as(usize, 5), count);
    try std.testing.expectEqualStrings(
        "1. Root VM & Hardware Partitioning",
        steps[0].title(),
    );
    try std.testing.expectEqualStrings(
        "dsx host info",
        steps[0].cliHint(),
    );
    try std.testing.expectEqualStrings(
        "5. Zero-Password Passkey Authentication",
        steps[4].title(),
    );
    try std.testing.expectEqualStrings(
        "dsx auth status",
        steps[4].cliHint(),
    );
}
