const std = @import("std");
const ui = @import("ui.zig");

pub const ConfigApp = struct {
    allocator: std.mem.Allocator,
    canvas: ui.Canvas,
    current_tab: ui.Tab = .dashboard,
    vms: std.ArrayList(ui.VmCard),

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !ConfigApp {
        var app = ConfigApp{
            .allocator = allocator,
            .canvas = try ui.Canvas.init(allocator, width, height),
            .vms = std.ArrayList(ui.VmCard).empty,
        };

        // Populate sample VM state
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

        // 1. Clear background
        self.canvas.fillRect(.{ .x = 0, .y = 0, .w = w, .h = h }, ui.Color.BG);

        // 2. Left Sidebar (Navigation)
        const sidebar_w: u32 = 180;
        self.canvas.fillRect(.{ .x = 0, .y = 0, .w = sidebar_w, .h = h }, ui.Color.SIDEBAR_BG);
        self.canvas.fillRect(.{ .x = @as(i32, @intCast(sidebar_w - 1)), .y = 0, .w = 1, .h = h }, ui.Color.CARD_BORDER);

        // Sidebar Navigation Items
        var tab_y: i32 = 20;
        const tab_height: u32 = 36;
        var tab_idx: usize = 0;
        while (tab_idx < 4) : (tab_idx += 1) {
            const is_active = (tab_idx == @intFromEnum(self.current_tab));
            if (is_active) {
                self.canvas.fillRect(.{ .x = 10, .y = tab_y, .w = sidebar_w - 20, .h = tab_height }, ui.Color.CARD_BG);
                self.canvas.fillRect(.{ .x = 10, .y = tab_y, .w = 4, .h = tab_height }, ui.Color.ACCENT_GREEN);
            }
            tab_y += @as(i32, @intCast(tab_height + 8));
        }

        // 3. Main Content Area: VM Cards List
        const content_x: i32 = @as(i32, @intCast(sidebar_w)) + 20;
        var card_y: i32 = 20;
        const card_w: u32 = w - sidebar_w - 40;
        const card_h: u32 = 50;

        for (self.vms.items) |*vm| {
            vm.render(&self.canvas, .{
                .x = content_x,
                .y = card_y,
                .w = card_w,
                .h = card_h,
            });
            card_y += @as(i32, @intCast(card_h + 12));
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try ConfigApp.init(allocator, 800, 500);
    defer app.deinit();

    app.render();

    var stdout_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&stdout_buf, "Diosix Configuration Manager (diosix-config) rendered {d}x{d} surface.\n", .{ app.canvas.width, app.canvas.height }) catch return;
    _ = std.posix.write(std.posix.STDOUT_FILENO, msg) catch {};
}

test "diosix-config: canvas rendering and vm card layout" {
    const testing = std.testing;
    var app = try ConfigApp.init(testing.allocator, 640, 400);
    defer app.deinit();

    app.render();

    try testing.expectEqual(@as(u32, 640), app.canvas.width);
    try testing.expectEqual(@as(u32, 400), app.canvas.height);
    try testing.expectEqual(@as(usize, 3), app.vms.items.len);

    // Verify sidebar background is painted
    const sidebar_pixel = app.canvas.pixels[50 * 640 + 50];
    try testing.expect(sidebar_pixel != ui.Color.BG);
}
