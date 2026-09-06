const std = @import("std");
const fb = @import("framebuffer.zig");

pub const Sprites = struct {
    // 16x16 RISC OS Window Furniture Sprites

    // Acorn RISC OS 3D Close Cross (Red with highlight and shadow outline)
    // '.' = transparent, 'D' = dark red/shadow, 'R' = Acorn bright red, 'L' = light red highlight
    const CLOSE_SPRITE = [16][]const u8{
        "................",
        "................",
        "...DD......DD...",
        "..DLRD....DLRD..",
        "..DLRRD..DLRRD..",
        "...DLRRDDLRRD...",
        "....DLRRRRRD....",
        ".....DLRRRD.....",
        "....DLRRRRRD....",
        "...DLRRDDLRRD...",
        "..DLRRD..DLRRD..",
        "..DLRD....DLRD..",
        "...DD......DD...",
        "................",
        "................",
        "................",
    };

    // RISC OS Back Icon (Overlapping windows: active front window in front of inactive back window)
    // '.' = transparent, 'B' = black/outline, 'W' = white body, 'T' = inactive titlebar grey,
    // 'A' = active titlebar cream, 'S' = drop shadow
    const BACK_SPRITE = [16][]const u8{
        "................",
        "..BBBBBBB.......",
        "..BTTTTTB.......",
        "..BWWWWWB.......",
        "..BWWBBBBBBB....",
        "..BWWBAAAAAB....",
        "..BBBBAWWWWBS...",
        ".....BAWWWWBS...",
        ".....BAWWWWBS...",
        ".....BAWWWWBS...",
        ".....BBBBBBBS...",
        "......SSSSSSS...",
        "................",
        "................",
        "................",
        "................",
    };

    // RISC OS Toggle Size Icon (Window inside window / maximize restore)
    // '.' = transparent, 'B' = black outline, 'A' = titlebar, 'W' = body, 'S' = shadow
    const TOGGLE_SPRITE = [16][]const u8{
        "................",
        "..BBBBBBBBBBB...",
        "..BAAAAAAAAAAB..",
        "..BWWWWWWWWWWBS.",
        "..BWBBBBBBBWWBS.",
        "..BWBAAAAABWWBS.",
        "..BWBWWWWWBWWBS.",
        "..BWBWWWWWBWWBS.",
        "..BWBBBBBBBWWBS.",
        "..BWWWWWWWWWWBS.",
        "..BBBBBBBBBBBBS.",
        "...SSSSSSSSSSSS.",
        "................",
        "................",
        "................",
        "................",
    };

    // Up Arrow (Solid 3D RISC OS scroll stepper)
    const UP_ARROW_SPRITE = [16][]const u8{
        "................",
        "................",
        ".......BB.......",
        "......BBBB......",
        ".....BBBBBB.....",
        "....BBBBBBBB....",
        "...BBBBBBBBBB...",
        "..BBBBBBBBBBBB..",
        "..BSSSSSSSSSSB..",
        "................",
        "................",
        "................",
        "................",
        "................",
        "................",
        "................",
    };

    // Down Arrow (Solid 3D RISC OS scroll stepper)
    const DOWN_ARROW_SPRITE = [16][]const u8{
        "................",
        "................",
        "................",
        "................",
        "..BSSSSSSSSSSB..",
        "..BBBBBBBBBBBB..",
        "...BBBBBBBBBB...",
        "....BBBBBBBB....",
        ".....BBBBBB.....",
        "......BBBB......",
        ".......BB.......",
        "................",
        "................",
        "................",
        "................",
        "................",
    };

    // Left Arrow
    const LEFT_ARROW_SPRITE = [16][]const u8{
        "................",
        "................",
        ".......BB.......",
        "......BBB.......",
        ".....BBBB.......",
        "....BBBBB.......",
        "...BBBBBB.......",
        "..BBBBBBB.......",
        "...BBBBBB.......",
        "....BBBBB.......",
        ".....BBBB.......",
        "......BBB.......",
        ".......BB.......",
        "................",
        "................",
        "................",
    };

    // Right Arrow
    const RIGHT_ARROW_SPRITE = [16][]const u8{
        "................",
        "................",
        ".......BB.......",
        ".......BBB......",
        ".......BBBB.....",
        ".......BBBBB....",
        ".......BBBBBB...",
        ".......BBBBBBB..",
        ".......BBBBBB...",
        ".......BBBBB....",
        ".......BBBB.....",
        ".......BBB......",
        ".......BB.......",
        "................",
        "................",
        "................",
    };

    fn draw16x16(surface: *fb.Surface, box: fb.Box, sprite: [16][]const u8, palette: *const fn (u8) ?u32) void {
        const ox = box.x0 + @divFloor(@as(i32, @intCast(box.width())) - 16, 2);
        const oy = box.y0 + @divFloor(@as(i32, @intCast(box.height())) - 16, 2);

        for (sprite, 0..) |row, y| {
            for (row, 0..) |ch, x| {
                if (palette(ch)) |color| {
                    surface.setPixel(ox + @as(i32, @intCast(x)), oy + @as(i32, @intCast(y)), color);
                }
            }
        }
    }

    fn closePalette(ch: u8) ?u32 {
        return switch (ch) {
            'D' => 0xFF600000, // Dark crimson outline
            'R' => fb.Color.ACORN_RED, // Acorn pure red (0xFFD42B2B)
            'L' => 0xFFFF6666, // Light red highlight
            else => null,
        };
    }

    fn windowPalette(ch: u8) ?u32 {
        return switch (ch) {
            'B' => fb.Color.BLACK,
            'W' => fb.Color.WHITE,
            'T' => fb.Color.TITLE_INACTIVE,
            'A' => fb.Color.TITLE_ACTIVE,
            'S' => fb.Color.BEVEL_DARK,
            else => null,
        };
    }

    fn arrowPalette(ch: u8) ?u32 {
        return switch (ch) {
            'B' => fb.Color.BLACK,
            'S' => fb.Color.BEVEL_DARK,
            else => null,
        };
    }

    pub fn drawCloseIcon(surface: *fb.Surface, box: fb.Box) void {
        draw16x16(surface, box, CLOSE_SPRITE, closePalette);
    }

    pub fn drawBackIcon(surface: *fb.Surface, box: fb.Box) void {
        draw16x16(surface, box, BACK_SPRITE, windowPalette);
    }

    pub fn drawToggleIcon(surface: *fb.Surface, box: fb.Box) void {
        draw16x16(surface, box, TOGGLE_SPRITE, windowPalette);
    }

    pub fn drawUpArrow(surface: *fb.Surface, box: fb.Box) void {
        draw16x16(surface, box, UP_ARROW_SPRITE, arrowPalette);
    }

    pub fn drawDownArrow(surface: *fb.Surface, box: fb.Box) void {
        draw16x16(surface, box, DOWN_ARROW_SPRITE, arrowPalette);
    }

    pub fn drawLeftArrow(surface: *fb.Surface, box: fb.Box) void {
        draw16x16(surface, box, LEFT_ARROW_SPRITE, arrowPalette);
    }

    pub fn drawRightArrow(surface: *fb.Surface, box: fb.Box) void {
        draw16x16(surface, box, RIGHT_ARROW_SPRITE, arrowPalette);
    }

    // 3 Embossed Tactile Ridges on Scrollbar Sausages
    pub fn drawVerticalSausageGrip(surface: *fb.Surface, box: fb.Box) void {
        if (box.height() < 16) return;
        const mid_y = box.y0 + @divFloor(@as(i32, @intCast(box.height())), 2);
        const x_start = box.x0 + 3;
        const x_end = box.x1 - 3;
        if (x_end <= x_start) return;

        const offsets = [_]i32{ -3, 0, 3 };
        for (offsets) |dy| {
            const y_dark = mid_y + dy;
            const y_light = y_dark + 1;
            var x = x_start;
            while (x < x_end) : (x += 1) {
                surface.setPixel(x, y_dark, fb.Color.BEVEL_DARK);
                surface.setPixel(x, y_light, fb.Color.BEVEL_LIGHT);
            }
        }
    }

    pub fn drawHorizontalSausageGrip(surface: *fb.Surface, box: fb.Box) void {
        if (box.width() < 16) return;
        const mid_x = box.x0 + @divFloor(@as(i32, @intCast(box.width())), 2);
        const y_start = box.y0 + 3;
        const y_end = box.y1 - 3;
        if (y_end <= y_start) return;

        const offsets = [_]i32{ -3, 0, 3 };
        for (offsets) |dx| {
            const x_dark = mid_x + dx;
            const x_light = x_dark + 1;
            var y = y_start;
            while (y < y_end) : (y += 1) {
                surface.setPixel(x_dark, y, fb.Color.BEVEL_DARK);
                surface.setPixel(x_light, y, fb.Color.BEVEL_LIGHT);
            }
        }
    }
};
