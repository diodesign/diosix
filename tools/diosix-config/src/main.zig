// Diosix Configuration Manager Application Entry Point.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const ui = @import("ui.zig");

pub const ConfigApp = struct {
    allocator: std.mem.Allocator,
    canvas: ui.Canvas,
    current_tab: ui.Tab = .dashboard,
    vms: std.ArrayList(ui.VmCard),

    pub fn init(
        allocator: std.mem.Allocator,
        width: u32,
        height: u32,
    ) !ConfigApp {
        var app = ConfigApp{
            .allocator = allocator,
            .canvas = try ui.Canvas.init(allocator, width, height),
            .vms = std.ArrayList(ui.VmCard).empty,
        };
        errdefer app.deinit();

        // Populate sample VM state.
        try app.vms.append(allocator, .{
            .name = "root (self)",
            .cid = 1,
            .vcpus = 4,
            .ram_mb = 512,
            .is_running = true,
            .is_trusted = true,
        });

        try app.vms.append(allocator, .{
            .name = "gui-domain",
            .cid = 2,
            .vcpus = 2,
            .ram_mb = 512,
            .is_running = true,
            .is_trusted = true,
        });

        try app.vms.append(allocator, .{
            .name = "user-work",
            .cid = 4,
            .vcpus = 2,
            .ram_mb = 1024,
            .is_running = true,
            .is_trusted = false,
            .disk = "user-data.img",
        });

        return app;
    }

    pub fn deinit(self: *ConfigApp) void {
        self.canvas.deinit(self.allocator);
        self.vms.deinit(self.allocator);
    }

    pub fn render(self: *ConfigApp) void {
        const w = self.canvas.width;
        const h = self.canvas.height;

        // 1. Clear background.
        self.canvas.fillRect(
            .{ .x = 0, .y = 0, .w = w, .h = h },
            ui.Color.BG,
        );

        // 2. Left sidebar (navigation).
        const sidebar_w: u32 = ui.Layout.SIDEBAR_WIDTH;
        self.canvas.fillRect(
            .{ .x = 0, .y = 0, .w = sidebar_w, .h = h },
            ui.Color.SIDEBAR_BG,
        );
        self.canvas.fillRect(
            .{
                .x = @as(i32, @intCast(sidebar_w - 1)),
                .y = 0,
                .w = ui.Layout.CARD_BORDER_WIDTH,
                .h = h,
            },
            ui.Color.CARD_BORDER,
        );

        // Sidebar navigation items.
        var tab_y: i32 = ui.Layout.TAB_START_Y;
        const tab_height: u32 = ui.Layout.TAB_HEIGHT;
        var tab_idx: usize = 0;
        while (tab_idx < ui.Layout.TAB_COUNT) : (tab_idx += 1) {
            const is_active = (tab_idx == @backingInt(self.current_tab));
            if (is_active) {
                self.canvas.fillRect(
                    .{
                        .x = ui.Layout.SIDEBAR_MARGIN_X,
                        .y = tab_y,
                        .w = sidebar_w - ui.Layout.SIDEBAR_PADDING_W,
                        .h = tab_height,
                    },
                    ui.Color.CARD_BG,
                );
                self.canvas.fillRect(
                    .{
                        .x = ui.Layout.SIDEBAR_MARGIN_X,
                        .y = tab_y,
                        .w = ui.Layout.TAB_INDICATOR_W,
                        .h = tab_height,
                    },
                    ui.Color.ACCENT_GREEN,
                );
            }
            tab_y += @as(i32, @intCast(tab_height + ui.Layout.TAB_GAP));
        }

        // 3. Main content area: VM cards list.
        const margin_i32: i32 = @intCast(ui.Layout.CONTENT_MARGIN);
        const content_x: i32 = @as(i32, @intCast(sidebar_w)) + margin_i32;
        var card_y: i32 = margin_i32;
        const card_w: u32 = w -| (sidebar_w + ui.Layout.CONTENT_MARGIN * 2);
        const card_h: u32 = ui.Layout.CARD_HEIGHT;

        for (self.vms.items) |*vm| {
            vm.render(&self.canvas, .{
                .x = content_x,
                .y = card_y,
                .w = card_w,
                .h = card_h,
            });
            card_y += @as(i32, @intCast(card_h + ui.Layout.CARD_GAP));
        }
    }
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var app = try ConfigApp.init(
        allocator,
        ui.Layout.DEFAULT_WINDOW_WIDTH,
        ui.Layout.DEFAULT_WINDOW_HEIGHT,
    );
    defer app.deinit();

    app.render();

    const msg = try allocator.print(
        "Diosix Configuration Manager (diosix-config) rendered {d}x{d} " ++
            "surface.\n",
        .{ app.canvas.width, app.canvas.height },
    );
    defer allocator.free(msg);
    _ = std.os.linux.write(std.os.linux.STDOUT_FILENO, msg.ptr, msg.len);
}

test "diosix-config: canvas rendering and vm card layout" {
    const testing = std.testing;
    var app = try ConfigApp.init(testing.allocator, 640, 400);
    defer app.deinit();

    app.render();

    try testing.expectEqual(@as(u32, 640), app.canvas.width);
    try testing.expectEqual(@as(u32, 400), app.canvas.height);
    try testing.expectEqual(@as(usize, 3), app.vms.items.len);

    // Verify sidebar background is painted.
    const sidebar_pixel = app.canvas.pixels[50 * 640 + 50];
    try testing.expect(sidebar_pixel != ui.Color.BG);
}

test {
    _ = ui;
    std.testing.refAllDecls(@This());
}
