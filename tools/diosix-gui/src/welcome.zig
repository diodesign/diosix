// First-Boot Welcome Modal & 5-Step Guided Tour for Diosix GUI & CLI.
//
// Provides the Live Test-Drive vs. Host Install Welcome experience and an
// interactive 5-step architectural tour accessible both in diosix-gui and via
// `dsx tour`.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const paths = @import("paths.zig");

pub const DEFAULT_SYSCONFIG_PATH: [*:0]const u8 = paths.DEFAULT_SYSCONFIG_PATH;
pub const TOUR_STEP_COUNT: usize = 5;

pub const TourStep = struct {
    step_num: u8,
    title: []const u8,
    summary_line1: []const u8,
    summary_line2: []const u8,
    cli_hint: []const u8,
};

/// Capacity of a custom tour step title: one line in the tour modal header.
pub const TOUR_TITLE_MAX_BYTES: usize = 96;
/// Capacity of each custom tour summary line: one 20px-high modal row.
pub const TOUR_SUMMARY_MAX_BYTES: usize = 128;
/// Capacity of a custom tour CLI hint, shown after "CLI equivalent: ".
pub const TOUR_HINT_MAX_BYTES: usize = 96;

/// Size of each read() when slurping the system config file.
const CONFIG_READ_CHUNK_BYTES: usize = 4096;
/// Upper bound on the system config we are willing to hold in memory.
const MAX_CONFIG_FILE_BYTES: usize = 1024 * 1024;

pub const CustomTourStep = struct {
    title_buf: [TOUR_TITLE_MAX_BYTES]u8 = @splat(0),
    title_len: usize = 0,
    summary1_buf: [TOUR_SUMMARY_MAX_BYTES]u8 = @splat(0),
    summary1_len: usize = 0,
    summary2_buf: [TOUR_SUMMARY_MAX_BYTES]u8 = @splat(0),
    summary2_len: usize = 0,
    hint_buf: [TOUR_HINT_MAX_BYTES]u8 = @splat(0),
    hint_len: usize = 0,
};

/// Copy `src` into `buf`, recording the stored length in `len_out`. Returns
/// true if `src` fitted; otherwise the largest prefix is stored and false is
/// returned so the caller can warn that the text was cut.
fn setBuf(buf: []u8, len_out: *usize, src: []const u8) bool {
    const n = @min(src.len, buf.len);
    @memcpy(buf[0..n], src[0..n]);
    len_out.* = n;
    return n == src.len;
}

/// Store a [[tour]] field from diosix.toml, warning if it had to be cut.
fn setTourField(
    buf: []u8,
    len_out: *usize,
    field: []const u8,
    src: []const u8,
) void {
    if (!setBuf(buf, len_out, src)) {
        std.debug.print(
            "diosix-gui: [[tour]] {s} is {d} bytes; truncated to {d}.\n",
            .{ field, src.len, buf.len },
        );
    }
}

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
    custom_steps: [TOUR_STEP_COUNT]CustomTourStep = @splat(.{}),
    custom_step_count: usize = 0,
    config_loaded: bool = false,

    pub fn loadTourToml(self: *WelcomeState, content: []const u8) void {
        var in_tour = false;
        var count: usize = 0;
        var active_idx: ?usize = null;

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |raw_line| {
            const trimmed = std.mem.trim(u8, raw_line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;
            if (trimmed[0] == '[') {
                if (std.mem.eql(u8, trimmed, "[[tour]]")) {
                    in_tour = true;
                    if (count < TOUR_STEP_COUNT) {
                        const def = TOUR_STEPS[count];
                        var cs = &self.custom_steps[count];
                        // Built-in defaults: all fit, checked by a test.
                        _ = setBuf(&cs.title_buf, &cs.title_len, def.title);
                        _ = setBuf(
                            &cs.summary1_buf,
                            &cs.summary1_len,
                            def.summary_line1,
                        );
                        _ = setBuf(
                            &cs.summary2_buf,
                            &cs.summary2_len,
                            def.summary_line2,
                        );
                        _ = setBuf(&cs.hint_buf, &cs.hint_len, def.cli_hint);
                        active_idx = count;
                        count += 1;
                    } else {
                        active_idx = null;
                    }
                } else {
                    in_tour = false;
                    active_idx = null;
                }
                continue;
            }
            if (!in_tour) continue;
            const idx = active_idx orelse continue;
            const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
            const key = std.mem.trim(u8, trimmed[0..eq], " \t");
            const val = std.mem.trim(u8, trimmed[eq + 1 ..], " \t\"'");
            if (val.len == 0) continue;

            var cs = &self.custom_steps[idx];
            if (std.mem.eql(u8, key, "title")) {
                setTourField(&cs.title_buf, &cs.title_len, key, val);
            } else if (std.mem.eql(u8, key, "summary")) {
                setTourField(&cs.summary1_buf, &cs.summary1_len, key, val);
            } else if (std.mem.eql(u8, key, "summary_line2")) {
                setTourField(&cs.summary2_buf, &cs.summary2_len, key, val);
            } else if (std.mem.eql(u8, key, "cli_hint")) {
                setTourField(&cs.hint_buf, &cs.hint_len, key, val);
            }
        }
        if (count > 0) {
            self.custom_step_count = count;
        }
        self.config_loaded = true;
    }

    pub fn ensureConfigLoaded(self: *WelcomeState) void {
        if (self.config_loaded) return;
        self.config_loaded = true;
        const fd_rc = linux.open(
            DEFAULT_SYSCONFIG_PATH,
            .{ .ACCMODE = .RDONLY },
            0,
        );
        const signed_fd: isize = @bitCast(fd_rc);
        if (signed_fd < 0) return;
        const fd: i32 = @intCast(signed_fd);
        defer _ = linux.close(fd);

        const allocator = std.heap.page_allocator;
        var content: std.ArrayList(u8) = .empty;
        defer content.deinit(allocator);
        while (content.items.len < MAX_CONFIG_FILE_BYTES) {
            content.ensureUnusedCapacity(
                allocator,
                CONFIG_READ_CHUNK_BYTES,
            ) catch {
                std.debug.print(
                    "diosix-gui: Out of memory reading config.\n",
                    .{},
                );
                break;
            };
            const spare = content.unusedCapacitySlice();
            const rd_rc = linux.read(fd, spare.ptr, spare.len);
            const signed_rd: isize = @bitCast(rd_rc);
            if (signed_rd <= 0) break;
            content.items.len += @intCast(signed_rd);
        }
        if (content.items.len >= MAX_CONFIG_FILE_BYTES) {
            std.debug.print(
                "diosix-gui: Config exceeds {d} bytes; ignoring the rest.\n",
                .{MAX_CONFIG_FILE_BYTES},
            );
        }
        if (content.items.len > 0) self.loadTourToml(content.items);
    }

    pub fn openWelcome(self: *WelcomeState) void {
        self.ensureConfigLoaded();
        self.welcome_visible = true;
        self.tour_visible = false;
    }

    pub fn closeWelcome(self: *WelcomeState) void {
        self.welcome_visible = false;
    }

    pub fn startTour(self: *WelcomeState) void {
        self.ensureConfigLoaded();
        self.welcome_visible = false;
        self.tour_visible = true;
        self.current_step = 0;
    }

    pub fn stepCount(self: *const WelcomeState) usize {
        return if (self.custom_step_count > 0)
            self.custom_step_count
        else
            TOUR_STEP_COUNT;
    }

    pub fn nextStep(self: *WelcomeState) void {
        if (self.current_step + 1 < self.stepCount()) {
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
        if (self.custom_step_count > 0) {
            const idx = @min(self.current_step, self.custom_step_count - 1);
            const cs = &self.custom_steps[idx];
            return .{
                .step_num = @intCast(idx + 1),
                .title = cs.title_buf[0..cs.title_len],
                .summary_line1 = cs.summary1_buf[0..cs.summary1_len],
                .summary_line2 = cs.summary2_buf[0..cs.summary2_len],
                .cli_hint = cs.hint_buf[0..cs.hint_len],
            };
        }
        const idx = @min(self.current_step, TOUR_STEP_COUNT - 1);
        return TOUR_STEPS[idx];
    }
};

// -----------------------------------------------------------------------------
// Unit Tests.
// -----------------------------------------------------------------------------
const testing = std.testing;

test "WelcomeState transitions through all 5 guided tour steps and closes" {
    testing.refAllDecls(@This());
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

test "WelcomeState loadTourToml parses [[tour]] blocks from diosix.toml" {
    var ws = WelcomeState{};
    ws.loadTourToml(
        \\[[tour]]
        \\title = "Custom Step 1"
        \\summary = "Custom summary line"
        \\cli_hint = "dsx host info"
    );
    try testing.expectEqual(@as(usize, 1), ws.stepCount());
    const step = ws.activeTourStep();
    try testing.expectEqualStrings("Custom Step 1", step.title);
    try testing.expectEqualStrings("Custom summary line", step.summary_line1);
    try testing.expectEqualStrings("dsx host info", step.cli_hint);
}

test "setBuf reports truncation and keeps the largest prefix" {
    var buf: [4]u8 = undefined;
    var len: usize = 0;
    try testing.expect(setBuf(&buf, &len, "abcd"));
    try testing.expectEqualStrings("abcd", buf[0..len]);
    try testing.expect(!setBuf(&buf, &len, "abcdef"));
    try testing.expectEqualStrings("abcd", buf[0..len]);
}

test "built-in tour text fits the custom step buffers" {
    for (TOUR_STEPS) |step| {
        try testing.expect(step.title.len <= TOUR_TITLE_MAX_BYTES);
        try testing.expect(step.summary_line1.len <= TOUR_SUMMARY_MAX_BYTES);
        try testing.expect(step.summary_line2.len <= TOUR_SUMMARY_MAX_BYTES);
        try testing.expect(step.cli_hint.len <= TOUR_HINT_MAX_BYTES);
    }
}
