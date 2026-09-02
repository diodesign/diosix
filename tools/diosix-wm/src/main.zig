const std = @import("std");
const fb = @import("framebuffer.zig");
const dec = @import("decorator.zig");
const seat = @import("seat.zig");
const panel = @import("panel.zig");
const wayland = @import("wayland.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stdout_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&stdout_buf, "Starting Diosix Homegrown Wayland Window Manager (diosix-wm)...\n", .{}) catch return;
    _ = std.posix.write(std.posix.STDOUT_FILENO, msg) catch {};

    var fb_dev = try fb.FramebufferDevice.init(allocator, "/dev/fb0");
    defer fb_dev.backbuffer.deinit(allocator);

    var wm_server = try wayland.WaylandCompositorServer.init(allocator, "/tmp/wayland-0");
    defer wm_server.deinit();

    var seat_mgr = seat.SeatManager{};

    // Seed default desktop with sample client windows
    try wm_server.addWindow(.{
        .x = 80,
        .y = 80,
        .width = 640,
        .height = 420,
        .title = "Diosix Host Configuration Manager",
        .domain_name = "sys.config",
        .cid = 3,
        .trust = .trusted_config,
        .is_active = true,
        .is_maximized = false,
    });

    try wm_server.addWindow(.{
        .x = 300,
        .y = 200,
        .width = 540,
        .height = 360,
        .title = "Web Browser (Sandboxed)",
        .domain_name = "user.web",
        .cid = 4,
        .trust = .untrusted_net,
        .is_active = false,
        .is_maximized = false,
    });

    // Single-frame composite rendering cycle
    renderFrame(&fb_dev, &wm_server, &seat_mgr);
}

pub fn renderFrame(fb_dev: *fb.FramebufferDevice, server: *wayland.WaylandCompositorServer, seat_mgr: *const seat.SeatManager) void {
    // 1. Clear background
    fb_dev.backbuffer.clear(fb.Color.DARK_BG);

    // 2. Render all windows bottom-to-top
    var active_win: ?*const dec.WindowState = null;
    for (server.windows.items) |*win| {
        dec.WindowDecorator.renderWindow(&fb_dev.backbuffer, win);
        if (win.is_active) {
            active_win = win;
        }
    }

    // 3. Render Top Panel
    panel.TopPanel.render(&fb_dev.backbuffer, active_win, server.windows.items.len);

    // 4. Render Mouse Pointer Sprite
    seat_mgr.pointer.drawCursor(&fb_dev.backbuffer);

    // 5. Swap / flush to physical scanout buffer
    fb_dev.swapBuffers();
}

test "diosix-wm: surface allocation and fillRect" {
    const testing = std.testing;
    var surf = try fb.Surface.init(testing.allocator, 100, 100);
    defer surf.deinit(testing.allocator);

    surf.fillRect(.{ .x = 10, .y = 10, .width = 20, .height = 20 }, fb.Color.TRUST_TRUSTED);
    const pixel_idx: usize = 15 * 100 + 15;
    try testing.expectEqual(fb.Color.TRUST_TRUSTED, surf.pixels[pixel_idx]);
}

test "diosix-wm: window decorator geometry & trusted border" {
    const testing = std.testing;
    const win = dec.WindowState{
        .x = 50,
        .y = 50,
        .width = 400,
        .height = 300,
        .title = "Test Domain Window",
        .domain_name = "sys.config",
        .cid = 3,
        .trust = .trusted_config,
        .is_active = true,
        .is_maximized = false,
    };

    const client_rect = win.getClientAreaRect();
    try testing.expectEqual(@as(i32, 52), client_rect.x);
    try testing.expectEqual(@as(i32, 78), client_rect.y);
    try testing.expectEqual(@as(u32, 396), client_rect.width);
    try testing.expectEqual(@as(u32, 270), client_rect.height);

    const titlebar_rect = win.getTitlebarRect();
    try testing.expectEqual(@as(i32, 50), titlebar_rect.x);
    try testing.expectEqual(@as(u32, 28), titlebar_rect.height);
}

test "diosix-wm: seat pointer window hit-testing and dragging" {
    const testing = std.testing;
    var windows = [_]dec.WindowState{
        .{
            .x = 100,
            .y = 100,
            .width = 300,
            .height = 200,
            .title = "Window 1",
            .domain_name = "sys.config",
            .cid = 2,
            .trust = .trusted_config,
            .is_active = false,
            .is_maximized = false,
        },
    };

    var seat_mgr = seat.SeatManager{};
    seat_mgr.pointer.x = 150;
    seat_mgr.pointer.y = 110; // inside titlebar (100..128)

    seat_mgr.handlePointerButton(0, true, &windows);
    try testing.expectEqual(@as(?usize, 0), seat_mgr.active_window_idx);
    try testing.expect(windows[0].is_active);
    try testing.expectEqual(@as(?usize, 0), seat_mgr.pointer.dragging_window);

    // Move pointer by +50, +20
    seat_mgr.handlePointerMove(50, 20, 1024, 768, &windows);
    try testing.expectEqual(@as(i32, 150), windows[0].x);
    try testing.expectEqual(@as(i32, 120), windows[0].y);

    // Release mouse button
    seat_mgr.handlePointerButton(0, false, &windows);
    try testing.expectEqual(@as(?usize, null), seat_mgr.pointer.dragging_window);
}
