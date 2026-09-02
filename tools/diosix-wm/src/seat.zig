const std = @import("std");
const fb = @import("framebuffer.zig");
const dec = @import("decorator.zig");

pub const Pointer = struct {
    x: i32 = 400,
    y: i32 = 300,
    button_left: bool = false,
    button_right: bool = false,
    dragging_window: ?usize = null,
    drag_offset_x: i32 = 0,
    drag_offset_y: i32 = 0,

    pub fn drawCursor(self: *const Pointer, surface: *fb.Surface) void {
        const px = self.x;
        const py = self.y;
        
        // Render 12x12 arrow cursor
        var row: i32 = 0;
        while (row < 12) : (row += 1) {
            var col: i32 = 0;
            while (col <= row and col < 8) : (col += 1) {
                surface.setPixel(px + col, py + row, fb.Color.WHITE);
            }
        }
        // Black outline for high contrast
        surface.setPixel(px, py, fb.Color.BLACK);
        surface.setPixel(px + 1, py, fb.Color.BLACK);
    }
};

pub const SeatManager = struct {
    pointer: Pointer = .{},
    active_window_idx: ?usize = null,

    pub fn handlePointerMove(self: *SeatManager, dx: i32, dy: i32, max_w: u32, max_h: u32, windows: []dec.WindowState) void {
        self.pointer.x = std.math.clamp(self.pointer.x + dx, 0, @as(i32, @intCast(max_w)) - 1);
        self.pointer.y = std.math.clamp(self.pointer.y + dy, 0, @as(i32, @intCast(max_h)) - 1);

        if (self.pointer.dragging_window) |win_idx| {
            if (win_idx < windows.len) {
                windows[win_idx].x = self.pointer.x - self.pointer.drag_offset_x;
                windows[win_idx].y = self.pointer.y - self.pointer.drag_offset_y;
            }
        }
    }

    pub fn handlePointerButton(self: *SeatManager, button: u32, is_press: bool, windows: []dec.WindowState) void {
        _ = button;
        self.pointer.button_left = is_press;

        if (is_press) {
            // Hit test windows in top-to-bottom order (reverse)
            var i: usize = windows.len;
            while (i > 0) {
                i -= 1;
                const win = &windows[i];
                const total_rect = fb.Rect{ .x = win.x, .y = win.y, .width = win.width, .height = win.height };
                if (total_rect.contains(self.pointer.x, self.pointer.y)) {
                    self.active_window_idx = i;
                    for (windows, 0..) |*w, idx| {
                        w.is_active = (idx == i);
                    }

                    // Check titlebar drag
                    const tb_rect = win.getTitlebarRect();
                    if (tb_rect.contains(self.pointer.x, self.pointer.y)) {
                        self.pointer.dragging_window = i;
                        self.pointer.drag_offset_x = self.pointer.x - win.x;
                        self.pointer.drag_offset_y = self.pointer.y - win.y;
                    }
                    break;
                }
            }
        } else {
            self.pointer.dragging_window = null;
        }
    }
};
