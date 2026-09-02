const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

pub const Color = struct {
    pub const BLACK: u32 = 0xFF000000;
    pub const WHITE: u32 = 0xFFFFFFFF;
    pub const DARK_BG: u32 = 0xFF141418;
    pub const PANEL_BG: u32 = 0xFF1E1E24;
    pub const TEXT_PRIMARY: u32 = 0xFFE0E0E6;
    pub const TEXT_MUTED: u32 = 0xFF8A8A96;
    
    // Domain Trust Colors
    pub const TRUST_TRUSTED: u32 = 0xFF2ECC71;   // Emerald Green (sys.config, root)
    pub const TRUST_WORK: u32 = 0xFF3498DB;      // Dodger Blue (work domain)
    pub const TRUST_UNTRUSTED: u32 = 0xFFE74C3C; // Alizarin Red (user.web, untrusted)
    pub const TRUST_SYSTEM: u32 = 0xFF9B59B6;    // Amethyst Purple (sys.net, sys.fs)
    
    pub const BORDER_INACTIVE: u32 = 0xFF3E3E4A;
    pub const TITLEBAR_BG: u32 = 0xFF282832;
    pub const BTN_CLOSE: u32 = 0xFFE74C3C;
    pub const BTN_MAXIMIZE: u32 = 0xFF2ECC71;
    pub const BTN_MINIMIZE: u32 = 0xFFF1C40F;
};

pub const Rect = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,

    pub fn contains(self: Rect, px: i32, py: i32) bool {
        return px >= self.x and px < self.x + @as(i32, @intCast(self.width)) and
               py >= self.y and py < self.y + @as(i32, @intCast(self.height));
    }
};

pub const Surface = struct {
    width: u32,
    height: u32,
    stride: u32, // bytes per row
    pixels: []u32,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !Surface {
        const pixel_count = width * height;
        const pixels = try allocator.alloc(u32, pixel_count);
        @memset(pixels, Color.DARK_BG);
        return Surface{
            .width = width,
            .height = height,
            .stride = width * 4,
            .pixels = pixels,
        };
    }

    pub fn deinit(self: *Surface, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }

    pub fn clear(self: *Surface, color: u32) void {
        @memset(self.pixels, color);
    }

    pub fn setPixel(self: *Surface, x: i32, y: i32, color: u32) void {
        if (x < 0 or y < 0 or x >= self.width or y >= self.height) return;
        const idx = @as(usize, @intCast(y)) * self.width + @as(usize, @intCast(x));
        self.pixels[idx] = color;
    }

    pub fn fillRect(self: *Surface, rect: Rect, color: u32) void {
        const x_start = @max(0, rect.x);
        const y_start = @max(0, rect.y);
        const x_end = @min(@as(i32, @intCast(self.width)), rect.x + @as(i32, @intCast(rect.width)));
        const y_end = @min(@as(i32, @intCast(self.height)), rect.y + @as(i32, @intCast(rect.height)));

        if (x_start >= x_end or y_start >= y_end) return;

        var y = y_start;
        while (y < y_end) : (y += 1) {
            const row_offset = @as(usize, @intCast(y)) * self.width;
            var x = x_start;
            while (x < x_end) : (x += 1) {
                self.pixels[row_offset + @as(usize, @intCast(x))] = color;
            }
        }
    }

    pub fn drawRectOutline(self: *Surface, rect: Rect, thickness: u32, color: u32) void {
        const t = @as(i32, @intCast(thickness));
        // Top
        self.fillRect(.{ .x = rect.x, .y = rect.y, .width = rect.width, .height = thickness }, color);
        // Bottom
        self.fillRect(.{ .x = rect.x, .y = rect.y + @as(i32, @intCast(rect.height)) - t, .width = rect.width, .height = thickness }, color);
        // Left
        self.fillRect(.{ .x = rect.x, .y = rect.y, .width = thickness, .height = rect.height }, color);
        // Right
        self.fillRect(.{ .x = rect.x + @as(i32, @intCast(rect.width)) - t, .y = rect.y, .width = thickness, .height = rect.height }, color);
    }

    pub fn blit(self: *Surface, src: []const u32, src_w: u32, src_h: u32, dst_x: i32, dst_y: i32) void {
        const x_start = @max(0, dst_x);
        const y_start = @max(0, dst_y);
        const x_end = @min(@as(i32, @intCast(self.width)), dst_x + @as(i32, @intCast(src_w)));
        const y_end = @min(@as(i32, @intCast(self.height)), dst_y + @as(i32, @intCast(src_h)));

        if (x_start >= x_end or y_start >= y_end) return;

        var y = y_start;
        while (y < y_end) : (y += 1) {
            const src_row = @as(usize, @intCast(y - dst_y)) * src_w;
            const dst_row = @as(usize, @intCast(y)) * self.width;
            var x = x_start;
            while (x < x_end) : (x += 1) {
                const src_col = @as(usize, @intCast(x - dst_x));
                const pixel = src[src_row + src_col];
                // Alpha blend if high byte != 0
                if ((pixel >> 24) != 0) {
                    self.pixels[dst_row + @as(usize, @intCast(x))] = pixel;
                }
            }
        }
    }
};

pub const FramebufferDevice = struct {
    fb_fd: i32,
    mapped_mem: []u32,
    screen_surface: Surface,
    backbuffer: Surface,
    width: u32,
    height: u32,

    pub fn init(allocator: std.mem.Allocator, fb_path: []const u8) !FramebufferDevice {
        var z_path: [256]u8 = undefined;
        @memcpy(z_path[0..fb_path.len], fb_path);
        z_path[fb_path.len] = 0;

        const fd = posix.open(z_path[0..fb_path.len :0], .{ .ACCMODE = .RDWR }, 0) catch |err| {
            // Fallback to virtual 1024x768 surface for headless testing
            _ = err;
            const w: u32 = 1024;
            const h: u32 = 768;
            const bb = try Surface.init(allocator, w, h);
            const fb_surf = try Surface.init(allocator, w, h);
            return FramebufferDevice{
                .fb_fd = -1,
                .mapped_mem = fb_surf.pixels,
                .screen_surface = fb_surf,
                .backbuffer = bb,
                .width = w,
                .height = h,
            };
        };

        const w: u32 = 1280;
        const h: u32 = 800;
        const total_bytes = w * h * 4;

        const map = posix.mmap(
            null,
            total_bytes,
            posix.PROT.READ | posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            fd,
            0,
        ) catch {
            posix.close(fd);
            return error.MmapFailed;
        };

        const pixels: [*]u32 = @ptrCast(@alignCast(map.ptr));
        const mapped_slice = pixels[0 .. w * h];
        const screen_surf = Surface{
            .width = w,
            .height = h,
            .stride = w * 4,
            .pixels = mapped_slice,
        };
        const bb = try Surface.init(allocator, w, h);

        return FramebufferDevice{
            .fb_fd = fd,
            .mapped_mem = mapped_slice,
            .screen_surface = screen_surf,
            .backbuffer = bb,
            .width = w,
            .height = h,
        };
    }

    pub fn swapBuffers(self: *FramebufferDevice) void {
        @memcpy(self.screen_surface.pixels, self.backbuffer.pixels);
    }
};
