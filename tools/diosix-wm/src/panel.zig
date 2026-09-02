const std = @import("std");
const fb = @import("framebuffer.zig");
const dec = @import("decorator.zig");

pub const TopPanel = struct {
    pub const HEIGHT: u32 = 32;

    pub fn render(surface: *fb.Surface, active_window: ?*const dec.WindowState, total_vms: usize) void {
        _ = total_vms;
        const panel_rect = fb.Rect{
            .x = 0,
            .y = 0,
            .width = surface.width,
            .height = HEIGHT,
        };

        // 1. Dark Top Bar
        surface.fillRect(panel_rect, fb.Color.PANEL_BG);
        surface.fillRect(.{ .x = 0, .y = @as(i32, @intCast(HEIGHT - 1)), .width = surface.width, .height = 1 }, fb.Color.BORDER_INACTIVE);

        // 2. Logo / System Pill (Top-Left)
        const logo_pill = fb.Rect{ .x = 8, .y = 5, .width = 80, .height = 22 };
        surface.fillRect(logo_pill, fb.Color.TITLEBAR_BG);
        surface.fillRect(.{ .x = 12, .y = 9, .width = 14, .height = 14 }, fb.Color.TRUST_TRUSTED);

        // 3. Active Domain Status Pill (Center)
        if (active_window) |win| {
            const domain_pill = fb.Rect{
                .x = @as(i32, @intCast(surface.width / 2)) - 100,
                .y = 5,
                .width = 200,
                .height = 22,
            };
            surface.fillRect(domain_pill, fb.Color.TITLEBAR_BG);
            surface.drawRectOutline(domain_pill, 1, win.trust.getColor());
            surface.fillRect(.{ .x = domain_pill.x + 6, .y = domain_pill.y + 6, .width = 10, .height = 10 }, win.trust.getColor());
        }

        // 4. Clock / Status Pill (Top-Right)
        const clock_pill = fb.Rect{
            .x = @as(i32, @intCast(surface.width)) - 90,
            .y = 5,
            .width = 82,
            .height = 22,
        };
        surface.fillRect(clock_pill, fb.Color.TITLEBAR_BG);
    }
};
