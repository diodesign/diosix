const std = @import("std");
const fb = @import("framebuffer.zig");

pub const DomainTrust = enum {
    trusted_config,  // sys.config, root
    work,            // user.work, user.dev
    untrusted_net,   // user.web, sandboxed apps
    system_service,  // sys.net, sys.fs

    pub fn getColor(self: DomainTrust) u32 {
        return switch (self) {
            .trusted_config => fb.Color.TRUST_TRUSTED,
            .work => fb.Color.TRUST_WORK,
            .untrusted_net => fb.Color.TRUST_UNTRUSTED,
            .system_service => fb.Color.TRUST_SYSTEM,
        };
    }

    pub fn getLabel(self: DomainTrust) []const u8 {
        return switch (self) {
            .trusted_config => "TRUSTED ADMIN",
            .work => "WORK DOMAIN",
            .untrusted_net => "SANDBOXED UNTRUSTED",
            .system_service => "SYSTEM SERVICE",
        };
    }
};

pub const WindowState = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    title: []const u8,
    domain_name: []const u8,
    cid: usize,
    trust: DomainTrust,
    is_active: bool,
    is_maximized: bool,
    client_pixels: ?[]const u32 = null,
    client_width: u32 = 0,
    client_height: u32 = 0,

    pub const TITLEBAR_HEIGHT: u32 = 28;
    pub const BORDER_WIDTH: u32 = 2;

    pub fn getClientAreaRect(self: *const WindowState) fb.Rect {
        return fb.Rect{
            .x = self.x + @as(i32, @intCast(BORDER_WIDTH)),
            .y = self.y + @as(i32, @intCast(TITLEBAR_HEIGHT)),
            .width = self.width - (BORDER_WIDTH * 2),
            .height = self.height - TITLEBAR_HEIGHT - BORDER_WIDTH,
        };
    }

    pub fn getTitlebarRect(self: *const WindowState) fb.Rect {
        return fb.Rect{
            .x = self.x,
            .y = self.y,
            .width = self.width,
            .height = TITLEBAR_HEIGHT,
        };
    }

    pub fn getCloseButtonRect(self: *const WindowState) fb.Rect {
        return fb.Rect{
            .x = self.x + @as(i32, @intCast(self.width)) - 22,
            .y = self.y + 7,
            .width = 14,
            .height = 14,
        };
    }
};

pub const WindowDecorator = struct {
    pub fn renderWindow(surface: *fb.Surface, win: *const WindowState) void {
        const border_color = if (win.is_active) win.trust.getColor() else fb.Color.BORDER_INACTIVE;
        const total_rect = fb.Rect{
            .x = win.x,
            .y = win.y,
            .width = win.width,
            .height = win.height,
        };

        // 1. Draw outer trust border
        surface.drawRectOutline(total_rect, WindowState.BORDER_WIDTH, border_color);

        // 2. Draw Titlebar background
        const tb_rect = win.getTitlebarRect();
        surface.fillRect(tb_rect, fb.Color.TITLEBAR_BG);

        // 3. Draw Domain trust indicator badge on top-left
        const badge_rect = fb.Rect{
            .x = win.x + 6,
            .y = win.y + 6,
            .width = 16,
            .height = 16,
        };
        surface.fillRect(badge_rect, win.trust.getColor());

        // 4. Draw window controls (Close / Maximize / Minimize dots)
        const close_rect = win.getCloseButtonRect();
        surface.fillRect(close_rect, fb.Color.BTN_CLOSE);

        const max_rect = fb.Rect{ .x = close_rect.x - 18, .y = close_rect.y, .width = 14, .height = 14 };
        surface.fillRect(max_rect, fb.Color.BTN_MAXIMIZE);

        const min_rect = fb.Rect{ .x = max_rect.x - 18, .y = max_rect.y, .width = 14, .height = 14 };
        surface.fillRect(min_rect, fb.Color.BTN_MINIMIZE);

        // 5. Draw Client Surface Contents
        const client_rect = win.getClientAreaRect();
        if (win.client_pixels) |cpixels| {
            surface.blit(cpixels, win.client_width, win.client_height, client_rect.x, client_rect.y);
        } else {
            surface.fillRect(client_rect, fb.Color.DARK_BG);
        }
    }
};
