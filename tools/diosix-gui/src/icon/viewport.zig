// Virtual Machine Display Viewport Renderer for Diosix GUI Icons.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const fb = @import("../framebuffer.zig");
const font = @import("../font.zig");
const icon_mod = @import("../icon.zig");
const text_label = @import("../label.zig");
const Icon = icon_mod.Icon;

pub fn renderVideoViewport(
    self: *const Icon,
    surface: *fb.Surface,
    sx: i32,
    sy: i32,
    box: fb.Box,
    is_win_active: bool,
) void {
    // 1. Monitor Bezel Frame.
    const border_col = if (self.is_focused and is_win_active)
        fb.Color.ACCENT_CYAN
    else
        fb.Color.GLASS_BORDER;
    const in_bg = fb.Color.INPUT_BG;
    surface.drawRoundedTranslucentBox(box, 6, in_bg, 240, border_col);

    // 2. Top Monitor Banner Bar (LED status dot + display controller title).
    const header_h: u32 = 24;
    const header_box = fb.Box.fromPosSize(sx, sy, self.width, header_h);
    surface.drawRoundedTranslucentBox(
        header_box,
        4,
        fb.Color.BTN_NORMAL_BG,
        220,
        null,
    );

    const led_col = if (self.video_has_signal)
        fb.Color.ACCENT_GREEN
    else
        fb.Color.ACCENT_RED;
    const led_box = fb.Box.fromPosSize(sx + 10, sy + 7, 10, 10);
    surface.drawRoundedTranslucentBox(led_box, 5, led_col, 255, fb.Color.WHITE);

    var hdr_buf: [text_label.LABEL_BUF_BYTES]u8 = undefined;
    const name = self.getText();
    const hdr_text = if (self.video_has_signal)
        (if (self.width >= 600)
            text_label.fmtLabel(
                &hdr_buf,
                "VIRTUAL DISPLAY 0: {s} (VirtIO-GPU 2D 1024x768 @ 60Hz)",
                .{name},
            )
        else
            text_label.fmtLabel(
                &hdr_buf,
                "DISPLAY: {s} (VirtIO-GPU 60Hz)",
                .{name},
            ))
    else if (self.width >= 600)
        text_label.fmtLabel(
            &hdr_buf,
            "VIRTUAL DISPLAY 0: {s} (HEADLESS / SERIAL CONSOLE ONLY)",
            .{name},
        )
    else
        text_label.fmtLabel(
            &hdr_buf,
            "DISPLAY: {s} (HEADLESS / SERIAL)",
            .{name},
        );

    const hdr_w: u32 = if (self.width > 36) self.width - 36 else 0;
    const hdr_clip = surface.pushClip(
        fb.Box.fromPosSize(sx + 28, sy, hdr_w, header_h),
    );
    const hdr_col = if (self.video_has_signal)
        fb.Color.ACCENT_CYAN
    else
        fb.Color.ACCENT_AMBER;
    font.drawTextWithShadow(
        surface,
        hdr_text,
        sx + 28,
        sy + 4,
        hdr_col,
        fb.Color.BLACK,
    );
    surface.popClip(hdr_clip);

    // 3. Screen Viewport Box.
    const sc_x = sx + 8;
    const sc_y = sy + @as(i32, @intCast(header_h)) + 4;
    const sc_w = if (self.width > 16) self.width - 16 else 1;
    const sc_h = if (self.height > header_h + 12)
        self.height - header_h - 12
    else
        1;
    const sc_box = fb.Box.fromPosSize(sc_x, sc_y, sc_w, sc_h);

    const screen_clip = surface.pushClip(sc_box);
    defer surface.popClip(screen_clip);

    if (self.video_has_signal) {
        renderActiveViewport(self, surface, sc_x, sc_y, sc_w, sc_h, sc_box);
    } else {
        renderHeadlessViewport(surface, sc_x, sc_y, sc_w, sc_h, sc_box);
    }
}

fn renderActiveViewport(
    self: *const Icon,
    surface: *fb.Surface,
    screen_x: i32,
    screen_y: i32,
    screen_w: u32,
    screen_h: u32,
    screen_box: fb.Box,
) void {
    surface.drawGraduatedBackgroundInBox(
        screen_box,
        fb.Color.VIEWPORT_DESKTOP_TOP,
        fb.Color.VIEWPORT_DESKTOP_BOT,
    );

    const bar_h: u32 = 18;
    const bar_box = fb.Box.fromPosSize(screen_x, screen_y, screen_w, bar_h);
    surface.fillBox(bar_box, fb.Color.VIEWPORT_BAR);
    const mid_x = screen_x + @divTrunc(@as(i32, @intCast(screen_w)), 2);
    const right_x = screen_x + @as(i32, @intCast(screen_w));
    if (screen_w >= 600) {
        font.drawText(
            surface,
            "Diosix Guest OS",
            screen_x + 8,
            screen_y + 2,
            fb.Color.WHITE,
        );
        font.drawText(
            surface,
            "riscv64 | IP: 10.0.3.2 | GPU: VirtIO-GPU",
            mid_x - 110,
            screen_y + 2,
            fb.Color.TEXT_MUTED,
        );
        font.drawText(
            surface,
            "15:48:22",
            right_x - 60,
            screen_y + 2,
            fb.Color.ACCENT_GOLD,
        );
    } else {
        font.drawText(
            surface,
            "Guest OS",
            screen_x + 8,
            screen_y + 2,
            fb.Color.WHITE,
        );
        font.drawText(
            surface,
            "10.0.3.2",
            mid_x - 28,
            screen_y + 2,
            fb.Color.TEXT_MUTED,
        );
        font.drawText(
            surface,
            "15:48",
            right_x - 46,
            screen_y + 2,
            fb.Color.ACCENT_GOLD,
        );
    }

    if (screen_w > 140 and screen_h > 120) {
        const term_x = screen_x + 24;
        const term_y = screen_y + 28;
        const term_w = if (screen_w > 48) screen_w - 48 else screen_w;
        const term_h = if (screen_h > 68) screen_h - 68 else screen_h;
        const term_box = fb.Box.fromPosSize(term_x, term_y, term_w, term_h);
        surface.drawRoundedTranslucentBox(
            term_box,
            4,
            fb.Color.VIEWPORT_TERM_BG,
            240,
            fb.Color.VIEWPORT_TERM_BORDER,
        );

        const ttitle_box = fb.Box.fromPosSize(term_x, term_y, term_w, 20);
        surface.drawRoundedTranslucentBox(
            ttitle_box,
            4,
            fb.Color.VIEWPORT_TERM_HDR,
            255,
            null,
        );
        const dot_r = fb.Box.fromPosSize(term_x + 8, term_y + 6, 8, 8);
        const dot_a = fb.Box.fromPosSize(term_x + 20, term_y + 6, 8, 8);
        const dot_g = fb.Box.fromPosSize(term_x + 32, term_y + 6, 8, 8);
        surface.fillBox(dot_r, fb.Color.ACCENT_RED);
        surface.fillBox(dot_a, fb.Color.ACCENT_AMBER);
        surface.fillBox(dot_g, fb.Color.ACCENT_GREEN);

        var term_title_buf: [text_label.LABEL_BUF_BYTES]u8 = undefined;
        const ttitle = text_label.fmtLabel(
            &term_title_buf,
            "Console: root@{s}:~",
            .{self.getText()},
        );
        font.drawText(surface, ttitle, term_x + 50, term_y + 3, fb.Color.WHITE);

        const l1_y = term_y + 26;
        const uname_str = if (term_w >= 500)
            "Linux 7.0.10-diosix (riscv64) #1 SMP PREEMPT_DYNAMIC"
        else
            "Linux 7.0.10-diosix (riscv64)";
        font.drawText(
            surface,
            uname_str,
            term_x + 10,
            l1_y,
            fb.Color.VIEWPORT_TEXT_DIM,
        );
        if (term_h > 50) {
            font.drawText(
                surface,
                "root@guest:~# dsx ps",
                term_x + 10,
                l1_y + 16,
                fb.Color.ACCENT_GREEN,
            );
        }
        if (term_h > 70) {
            font.drawText(
                surface,
                "CID  NAME       STATUS   VCPUS  RAM    IP",
                term_x + 10,
                l1_y + 32,
                fb.Color.TEXT_MUTED,
            );
        }
        if (term_h > 90) {
            var ps_buf: [text_label.LABEL_BUF_BYTES]u8 = undefined;
            const ps = text_label.fmtLabel(
                &ps_buf,
                "2    {s:<10} RUNNING  2      256MB  10.0.3.2",
                .{self.getText()},
            );
            font.drawText(surface, ps, term_x + 10, l1_y + 48, fb.Color.WHITE);
        }
        if (term_h > 110) {
            font.drawText(
                surface,
                "root@guest:~# _",
                term_x + 10,
                l1_y + 64,
                fb.Color.ACCENT_GREEN,
            );
        }
    }

    const bbar_y = screen_y + @as(i32, @intCast(screen_h)) - 18;
    const bbar_box = fb.Box.fromPosSize(screen_x, bbar_y, screen_w, 18);
    surface.fillBox(bbar_box, fb.Color.VIEWPORT_BOTTOM_BAR);
    const bstr = if (screen_w >= 600)
        "Format: X8R8G8B8 | DRM: /dev/dri/card0 | Scanout 0 (60.0 FPS)"
    else
        "DRM: /dev/dri/card0 | Scanout 60 FPS";
    font.drawText(surface, bstr, screen_x + 8, bbar_y + 2, fb.Color.TEXT_MUTED);
}

fn renderHeadlessViewport(
    surface: *fb.Surface,
    screen_x: i32,
    screen_y: i32,
    screen_w: u32,
    screen_h: u32,
    screen_box: fb.Box,
) void {
    surface.fillBox(screen_box, fb.Color.VIEWPORT_HEADLESS_BG);

    var gy: i32 = screen_y + 4;
    while (gy < screen_y + @as(i32, @intCast(screen_h))) : (gy += 8) {
        const line_box = fb.Box.fromPosSize(screen_x, gy, screen_w, 1);
        surface.fillBox(line_box, fb.Color.VIEWPORT_GRID_LINE);
    }

    const warn_w: u32 = if (screen_w > 40) screen_w - 40 else screen_w;
    const warn_h: u32 = if (screen_h > 60) screen_h - 60 else screen_h;
    const warn_x = screen_x + 20;
    const warn_y = screen_y + 20;
    const warn_box = fb.Box.fromPosSize(warn_x, warn_y, warn_w, warn_h);
    surface.drawRoundedTranslucentBox(
        warn_box,
        4,
        fb.Color.INPUT_BG,
        240,
        fb.Color.ACCENT_AMBER,
    );

    const wide = warn_w >= 500;
    const tx = if (wide) warn_x + 20 else warn_x + 14;
    const hdr = if (wide)
        "[ HEADLESS DOMAIN - NO VIDEO OUTPUT DEVICE ]"
    else
        "[ HEADLESS DOMAIN - NO VIDEO ]";
    const line1 = if (wide)
        "The selected virtual machine has no VirtIO-GPU display adapter."
    else
        "Virtual machine has no VirtIO-GPU display.";
    const line2 = if (wide)
        "Primary Console : 16550 UART Serial (/dev/ttyS0 @ 115200 baud)"
    else
        "Primary: 16550 UART (/dev/ttyS0)";
    const line3 = if (wide)
        "Remote Console  : Dropbear SSH Bridge (port 22 active)"
    else
        "Remote : Dropbear SSH Bridge (port 22)";
    const line4 = if (wide)
        "Use 'Open Virtual SSH Console' to interact with this domain."
    else
        "Use 'Open Virtual SSH' to interact.";

    font.drawTextWithShadow(
        surface,
        hdr,
        tx,
        warn_y + 16,
        fb.Color.ACCENT_AMBER,
        fb.Color.BLACK,
    );
    font.drawText(surface, line1, tx, warn_y + 40, fb.Color.WHITE);
    font.drawText(surface, line2, tx, warn_y + 64, fb.Color.TEXT_MUTED);
    font.drawText(surface, line3, tx, warn_y + 84, fb.Color.TEXT_MUTED);
    font.drawText(surface, line4, tx, warn_y + 110, fb.Color.ACCENT_CYAN);
}

pub fn renderSlateCard(
    self: *const Icon,
    surface: *fb.Surface,
    sx: i32,
    sy: i32,
    box: fb.Box,
) void {
    const is_card_hover = self.is_hovered;
    const card_bg: u32 = if (self.is_active_press)
        fb.Color.BTN_PRESS_BG
    else if (self.is_selected)
        fb.Color.rgb(18, 38, 58)
    else if (is_card_hover)
        fb.Color.BTN_HOVER_BG
    else
        fb.Color.GLASS_BG;

    const border_col: u32 = if (self.is_selected)
        (if (self.card_is_supervisor)
            fb.Color.ACCENT_GOLD
        else
            fb.Color.ACCENT_CYAN)
    else if (is_card_hover)
        fb.Color.GLASS_BTN_BORDER
    else
        fb.Color.GLASS_BORDER;

    const bg_alpha: u8 = if (self.is_selected)
        240
    else if (is_card_hover)
        220
    else
        180;
    surface.drawGlassPane(box, 6, card_bg, bg_alpha, border_col, false, false);

    const inner_w: u32 = if (self.width > 4) self.width - 4 else 0;
    const inner_h: u32 = if (self.height > 4) self.height - 4 else 0;
    const card_clip = surface.pushClip(
        fb.Box.fromPosSize(sx + 2, sy + 2, inner_w, inner_h),
    );
    defer surface.popClip(card_clip);

    const dot_box = fb.Box.fromPosSize(sx + 14, sy + 14, 8, 8);
    const dot_border = if (self.card_is_supervisor)
        fb.Color.ACCENT_GOLD
    else
        fb.Color.WHITE;
    const badge_col = self.card_badge_color;
    surface.drawRoundedTranslucentBox(dot_box, 4, badge_col, 255, dot_border);

    var badge_left_x: i32 = sx + @as(i32, @intCast(self.width)) - 12;
    if (self.card_badge_len > 0) {
        const badge_str = self.getCardBadge();
        const badge_w = font.measureString(badge_str);
        const pill_pad_x: u32 = 10;
        const pill_w = badge_w + pill_pad_x * 2;
        const pill_h: u32 = 24;
        const pill_x = sx + @as(i32, @intCast(self.width)) -
            @as(i32, @intCast(pill_w)) - 14;
        const pill_y = sy + 7;
        const pill_box = fb.Box.fromPosSize(pill_x, pill_y, pill_w, pill_h);
        badge_left_x = pill_x - 8;

        surface.drawRoundedTranslucentBox(pill_box, 4, badge_col, 65, null);
        font.drawTextWithShadow(
            surface,
            badge_str,
            pill_x + @as(i32, @intCast(pill_pad_x)),
            pill_y + 3,
            badge_col,
            fb.Color.BLACK,
        );
    }

    const title_x = sx + 30;
    const title_y = sy + 10;
    const avail_title_w: u32 = if (badge_left_x > title_x + 8)
        @intCast(badge_left_x - title_x - 8)
    else
        0;
    const clip_h = font.GLYPH_HEIGHT + 4;
    const title_clip = surface.pushClip(
        fb.Box.fromPosSize(title_x, title_y, avail_title_w, clip_h),
    );
    const title_color = if (self.card_is_supervisor)
        fb.Color.ACCENT_GOLD
    else if (self.is_selected or is_card_hover)
        fb.Color.ACCENT_CYAN
    else
        fb.Color.WHITE;
    font.drawTextWithShadow(
        surface,
        self.getText(),
        title_x,
        title_y,
        title_color,
        fb.Color.BLACK,
    );
    surface.popClip(title_clip);

    if (self.card_sub_len > 0) {
        const sub_x = sx + 30;
        const sub_y = sy + 30;
        const avail_sub_w: u32 = if (self.width > 44) self.width - 44 else 0;
        const sub_clip = surface.pushClip(
            fb.Box.fromPosSize(sub_x, sub_y, avail_sub_w, clip_h),
        );
        font.drawTextWithShadow(
            surface,
            self.getCardSubtitle(),
            sub_x,
            sub_y,
            0x00a0b4c8,
            fb.Color.BLACK,
        );
        surface.popClip(sub_clip);
    }
}

test {
    std.testing.refAllDecls(@This());
}
