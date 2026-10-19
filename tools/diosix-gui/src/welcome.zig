// First-Boot Welcome Modal & 5-Step Guided Tour for Diosix GUI & CLI.
//
// Provides the Live Test-Drive vs. Host Install Welcome experience and an
// interactive 5-step architectural tour accessible both in diosix-gui and via
// `dsx tour`.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub const TOUR_STEP_COUNT: usize = 5;

pub const TourStep = struct {
    step_num: u8,
    title: []const u8,
    summary_line1: []const u8,
    summary_line2: []const u8,
    cli_hint: []const u8,
};

pub const TOUR_STEPS = [TOUR_STEP_COUNT]TourStep{
    .{
        .step_num = 1,
        .title = "Step 1/5: Root VM & Hardware Isolation",
        .summary_line1 = "M-mode hypervisor enforces Stage-2 Sv39x4 / PMP " ++
            "isolation across a strictly hierarchical VM tree.",
        .summary_line2 = "The Root VM scales up to 25% of host resources " ++
            "(128-256 MB RAM, 1-4 vCPUs), leaving >=75% for guests.",
        .cli_hint = "dsx host info && dsx info",
    },
    .{
        .step_num = 2,
        .title = "Step 2/5: Zero-Password Passkey Security",
        .summary_line1 = "Password logins are disabled system-wide. " ++
            "Authenticate via FIDO2 USB tokens, TPM 2.0 platform passkeys,",
        .summary_line2 = "WebAuthn QR pairing, or single-use Ed25519 UART " ++
            "serial challenges.",
        .cli_hint = "dsx auth status && dsx auth list",
    },
    .{
        .step_num = 3,
        .title = "Step 3/5: Guest OS & Image Catalog",
        .summary_line1 = "Pull SHA-256 verified Guest OS installer ISOs " ++
            "(Debian, Alpine, FreeBSD, OpenBSD, NetBSD) and Steward VMs",
        .summary_line2 = "from /etc/diosix/catalog.toml and boot unmodified " ++
            "S/U-mode guests via guest-shim.",
        .cli_hint = "dsx image catalog && dsx image list",
    },
    .{
        .step_num = 4,
        .title = "Step 4/5: Autonomic Steward Collective & Charter",
        .summary_line1 = "Optionally deploy Tier-1 Steward VMs governed by " ++
            "/etc/diosix/constitution.md and an M-mode sealed Charter.",
        .summary_line2 = "Stewards collaborate over the Whisper Mesh and " ++
            "protect ratified workloads even if a Root VM fails.",
        .cli_hint = "dsx charter status",
    },
    .{
        .step_num = 5,
        .title = "Step 5/5: Live Test-Drive & Host Installation",
        .summary_line1 = "Explore Diosix in Live RAM mode or install " ++
            "persistently to NVMe/SATA/VirtIO storage using",
        .summary_line2 = "Basic Guided Mode (3-step wizard) or Expert " ++
            "Declarative Mode (diosix-install.toml).",
        .cli_hint = "dsx host install --mode basic --dry-run",
    },
};

pub const WelcomeState = struct {
    welcome_visible: bool = false,
    tour_visible: bool = false,
    current_step: usize = 0, // 0..4 index into TOUR_STEPS.
    install_requested: bool = false,

    pub fn openWelcome(self: *WelcomeState) void {
        self.welcome_visible = true;
        self.tour_visible = false;
    }

    pub fn closeWelcome(self: *WelcomeState) void {
        self.welcome_visible = false;
    }

    pub fn startTour(self: *WelcomeState) void {
        self.welcome_visible = false;
        self.tour_visible = true;
        self.current_step = 0;
    }

    pub fn nextStep(self: *WelcomeState) void {
        if (self.current_step + 1 < TOUR_STEP_COUNT) {
            self.current_step += 1;
        } else {
            self.tour_visible = false;
        }
    }

    pub fn prevStep(self: *WelcomeState) void {
        if (self.current_step > 0) {
            self.current_step -= 1;
        }
    }

    pub fn closeTour(self: *WelcomeState) void {
        self.tour_visible = false;
    }

    pub fn activeTourStep(self: *const WelcomeState) TourStep {
        return TOUR_STEPS[@min(self.current_step, TOUR_STEP_COUNT - 1)];
    }
};

pub fn formatTourStepCli(
    buf: []u8,
    step_idx: usize,
    json_mode: bool,
) []const u8 {
    const clamped = @min(step_idx, TOUR_STEP_COUNT - 1);
    const s = TOUR_STEPS[clamped];
    if (json_mode) {
        return std.fmt.bufPrint(
            buf,
            "{{\"step\":{d},\"total_steps\":{d},\"title\":\"{s}\"," ++
                "\"summary\":\"{s} {s}\",\"cli_hint\":\"{s}\"}}\n",
            .{
                s.step_num,
                TOUR_STEP_COUNT,
                s.title,
                s.summary_line1,
                s.summary_line2,
                s.cli_hint,
            },
        ) catch "";
    }
    return std.fmt.bufPrint(buf,
        \\=== {s} ===
        \\  {s}
        \\  {s}
        \\  Try command : {s}
        \\
    , .{
        s.title,
        s.summary_line1,
        s.summary_line2,
        s.cli_hint,
    }) catch "";
}

// -----------------------------------------------------------------------------
// Unit Tests.
// -----------------------------------------------------------------------------
const testing = std.testing;

test "WelcomeState transitions through all 5 guided tour steps and closes" {
    var ws = WelcomeState{};
    ws.openWelcome();
    try testing.expect(ws.welcome_visible);
    try testing.expect(!ws.tour_visible);

    ws.startTour();
    try testing.expect(!ws.welcome_visible);
    try testing.expect(ws.tour_visible);
    try testing.expectEqual(@as(usize, 0), ws.current_step);
    try testing.expectEqual(@as(u8, 1), ws.activeTourStep().step_num);

    ws.nextStep();
    ws.nextStep();
    try testing.expectEqual(@as(usize, 2), ws.current_step);
    ws.prevStep();
    try testing.expectEqual(@as(usize, 1), ws.current_step);

    ws.nextStep(); // 2.
    ws.nextStep(); // 3.
    ws.nextStep(); // 4 (step 5/5).
    try testing.expect(ws.tour_visible);
    ws.nextStep(); // Finishes tour.
    try testing.expect(!ws.tour_visible);
}

test "formatTourStepCli produces valid text and JSON" {
    var buf: [512]u8 = undefined;
    const txt = formatTourStepCli(&buf, 0, false);
    const expected = "Step 1/5: Root VM & Hardware Isolation";
    try testing.expect(std.mem.indexOf(u8, txt, expected) != null);

    const js = formatTourStepCli(&buf, 3, true);
    try testing.expect(std.mem.indexOf(u8, js, "\"step\":4") != null);
    try testing.expect(std.mem.indexOf(u8, js, "dsx charter status") != null);
}
