// Diosix Interactive Guided Tour Step Definitions & Defaults.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const common = @import("../common.zig");

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
        common.setFixedBuf(&self.title_buf, &self.title_len, s);
    }

    pub fn setSummary(self: *TourStep, s: []const u8) void {
        common.setFixedBuf(&self.summary_buf, &self.summary_len, s);
    }

    pub fn setHint(self: *TourStep, s: []const u8) void {
        common.setFixedBuf(&self.hint_buf, &self.hint_len, s);
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
        "Step 1/5: Root VM & Hardware Trust",
        "The Root VM (CID 1) orchestrates hardware drivers, storage " ++
            "volumes, and child VM lifecycles via M-mode SBI hypercalls.",
        "dsx host info && dsx info",
    );
    steps[1].set(
        "Step 2/5: Virtual Machine Fleet & Isolation",
        "Child VMs run in isolated Stage-2 memory partitions with " ++
            "private point-to-point networking and zero upward SSH access.",
        "dsx image catalog && dsx image list",
    );
    steps[2].set(
        "Step 3/5: Passkey & Zero-Password Security",
        "All password logins are disabled. Operators authenticate via " ++
            "FIDO2 USB/NFC keys, TPM 2.0 platform passkeys, QR pairing, " ++
            "or UART challenge-response.",
        "dsx auth status && dsx auth list",
    );
    steps[3].set(
        "Step 4/5: Autonomic Steward Collective",
        "Tier-1 Steward VMs enforce the sealed M-mode Constitutional " ++
            "Charter via M-of-N quorum ratification and Standby Root " ++
            "failover.",
        "dsx charter status && dsx charter audit",
    );
    steps[4].set(
        "Step 5/5: Bare-Metal Host Installation",
        "Install the immutable Diosix boot image and persistent " ++
            "storage partition onto physical NVMe or VirtIO disks.",
        "dsx host install --mode basic --dry-run",
    );
    return 5;
}

test "sysconfig/tour: initializes default 5-step guided tour" {
    std.testing.refAllDecls(@This());
    var steps: [MAX_TOUR_STEPS]TourStep = @splat(.{});
    const count = initDefaultTourSteps(&steps);
    try std.testing.expectEqual(@as(usize, 5), count);
    try std.testing.expectEqualStrings(
        "Step 1/5: Root VM & Hardware Trust",
        steps[0].title(),
    );
}
