// Display Resolution Presets, EDID Physical Size Heuristics & UI Scaling
// for Diosix GUI.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub const ResolutionPreset = enum(u8) {
    r800x600 = 0,
    r1024x768 = 1,
    r1280x720 = 2,
    r1280x800 = 3,
    r1600x900 = 4,
    r1920x1080 = 5,
    r2560x1440 = 6,
    r3840x2160 = 7,

    pub const COUNT: usize = 8;

    pub fn width(self: ResolutionPreset) u32 {
        return switch (self) {
            .r800x600 => 800,
            .r1024x768 => 1024,
            .r1280x720 => 1280,
            .r1280x800 => 1280,
            .r1600x900 => 1600,
            .r1920x1080 => 1920,
            .r2560x1440 => 2560,
            .r3840x2160 => 3840,
        };
    }

    pub fn height(self: ResolutionPreset) u32 {
        return switch (self) {
            .r800x600 => 600,
            .r1024x768 => 768,
            .r1280x720 => 720,
            .r1280x800 => 800,
            .r1600x900 => 900,
            .r1920x1080 => 1080,
            .r2560x1440 => 1440,
            .r3840x2160 => 2160,
        };
    }

    pub fn label(self: ResolutionPreset) []const u8 {
        return switch (self) {
            .r800x600 => "800x600 (SVGA)",
            .r1024x768 => "1024x768 (XGA)",
            .r1280x720 => "1280x720 (HD)",
            .r1280x800 => "1280x800 (WXGA)",
            .r1600x900 => "1600x900 (HD+)",
            .r1920x1080 => "1920x1080 (FHD)",
            .r2560x1440 => "2560x1440 (QHD)",
            .r3840x2160 => "3840x2160 (4K UHD)",
        };
    }

    pub fn fromIndex(idx: usize) ResolutionPreset {
        return switch (idx) {
            0 => .r800x600,
            1 => .r1024x768,
            2 => .r1280x720,
            3 => .r1280x800,
            4 => .r1600x900,
            5 => .r1920x1080,
            6 => .r2560x1440,
            else => .r3840x2160,
        };
    }

    pub fn fromDimensions(w: u32, h: u32) ResolutionPreset {
        if (w <= 800 and h <= 600) return .r800x600;
        if (w == 1024 and h == 768) return .r1024x768;
        if (w == 1280 and h == 720) return .r1280x720;
        if (w == 1280 and h == 800) return .r1280x800;
        if (w == 1600 and h == 900) return .r1600x900;
        if (w == 1920 and h == 1080) return .r1920x1080;
        if (w == 2560 and h == 1440) return .r2560x1440;
        if (w >= 3840 or h >= 2160) return .r3840x2160;
        if (w >= 2560) return .r2560x1440;
        if (w >= 1920) return .r1920x1080;
        if (w >= 1600) return .r1600x900;
        return .r1280x800;
    }
};

pub const UiScaleMode = enum(u8) {
    auto = 0,
    pct_75 = 1,
    pct_100 = 2,
    pct_125 = 3,
    pct_150 = 4,
    pct_200 = 5,

    pub const COUNT: usize = 6;

    pub fn label(self: UiScaleMode) []const u8 {
        return switch (self) {
            .auto => "Auto (EDID / Display)",
            .pct_75 => "75% (Compact)",
            .pct_100 => "100% (Standard)",
            .pct_125 => "125% (Medium)",
            .pct_150 => "150% (Large)",
            .pct_200 => "200% (4K HiDPI)",
        };
    }

    pub fn fromIndex(idx: usize) UiScaleMode {
        return switch (idx) {
            0 => .auto,
            1 => .pct_75,
            2 => .pct_100,
            3 => .pct_125,
            4 => .pct_150,
            else => .pct_200,
        };
    }
};

fn heuristicScaleForResolution(width_px: u32, height_px: u32) u32 {
    if (width_px <= 960 or height_px <= 640) return 75;
    if (width_px >= 3200 or height_px >= 1800) return 200;
    if (width_px >= 2400 or height_px >= 1350) return 150;
    if (width_px >= 1920 and height_px >= 1080) return 125;
    return 100;
}

fn snapToStandardScale(raw_pct: f32) u32 {
    if (raw_pct < 87.5) return 75;
    if (raw_pct < 115.0) return 100;
    if (raw_pct < 137.5) return 125;
    if (raw_pct < 175.0) return 150;
    return 200;
}

/// Computes automatic UI scale percentage (`75`, `100`, `125`, `150`, `200`)
/// using DRM/KMS EDID physical dimensions (`mm_width`, `mm_height`) with
/// industry-standard sanity checks for virtual GPUs, projectors, and HDMI TVs.
pub fn detectPhysicalDpiScale(
    width_px: u32,
    height_px: u32,
    mm_width: u32,
    mm_height: u32,
) u32 {
    // 1. Missing or aspect-ratio-only EDID dimensions (e.g. 0x0 or 160x90 mm).
    if (mm_width < 120 or mm_height < 70) {
        return heuristicScaleForResolution(width_px, height_px);
    }

    const mw_f: f32 = @floatFromInt(mm_width);
    const mh_f: f32 = @floatFromInt(mm_height);
    const diag_mm = @sqrt(mw_f * mw_f + mh_f * mh_f);
    const diag_inches = diag_mm / 25.4;

    // 2. Large-format HDMI TVs (>= 42" diagonal) viewed from 10-foot distance.
    if (diag_inches >= 42.0) {
        if (width_px >= 3200) return 200;
        if (width_px >= 1920) return 125;
        return 100;
    }

    const w_f: f32 = @floatFromInt(width_px);
    const dpi_x = (w_f * 25.4) / mw_f;

    // 3. Virtual GPU drivers (virtio-gpu/bochs) synthesize ~96 DPI physical
    //    sizes proportional to pixel resolution. When resolution is FHD/QHD/4K
    //    and DPI is suspiciously pinned near 96 DPI, use resolution heuristic.
    if (width_px >= 1920 and dpi_x >= 90.0 and dpi_x <= 102.0) {
        return heuristicScaleForResolution(width_px, height_px);
    }

    const raw_pct = (dpi_x / 96.0) * 100.0;
    return snapToStandardScale(raw_pct);
}

pub fn resolveEffectiveScalePercent(
    mode: UiScaleMode,
    width_px: u32,
    height_px: u32,
    mm_width: u32,
    mm_height: u32,
) u32 {
    return switch (mode) {
        .auto => detectPhysicalDpiScale(
            width_px,
            height_px,
            mm_width,
            mm_height,
        ),
        .pct_75 => 75,
        .pct_100 => 100,
        .pct_125 => 125,
        .pct_150 => 150,
        .pct_200 => 200,
    };
}

pub fn scaleDim(base_px: u32, scale_pct: u32) u32 {
    return @max(1, (base_px * scale_pct + 50) / 100);
}

test "scale: EDID DPI detection and resolution presets" {
    std.testing.refAllDecls(@This());
    // 800x600 with no EDID -> 75% compact scale.
    try std.testing.expectEqual(
        @as(u32, 75),
        detectPhysicalDpiScale(800, 600, 0, 0),
    );
    // 1280x800 standard display -> 100% scale.
    try std.testing.expectEqual(
        @as(u32, 100),
        detectPhysicalDpiScale(1280, 800, 300, 190),
    );
    // 27-inch 4K monitor (600x340 mm, ~163 DPI) -> 150% or 200% HiDPI scale.
    try std.testing.expect(
        detectPhysicalDpiScale(3840, 2160, 600, 340) >= 150,
    );
    // 65-inch 4K HDMI TV (1440x810 mm) -> 200% 10-foot scale.
    try std.testing.expectEqual(
        @as(u32, 200),
        detectPhysicalDpiScale(3840, 2160, 1440, 810),
    );
}
