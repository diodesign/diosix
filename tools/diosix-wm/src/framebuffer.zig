const std = @import("std");
const linux = std.os.linux;

pub const Color = struct {
    pub const BLACK: u32 = 0xFF000000;
    pub const WHITE: u32 = 0xFFFFFFFF;

    // Classic Acorn RISC OS Palette
    pub const DESKTOP_BG: u32 = 0xFFC0C0C0; // Medium Acorn Desktop Grey
    pub const WINDOW_BG: u32 = 0xFFFFFFFF; // White client area
    pub const WINDOW_FRAME: u32 = 0xFFD6D6D6; // Light cream-grey frame
    pub const BEVEL_LIGHT: u32 = 0xFFFFFFFF; // 3D highlight
    pub const BEVEL_DARK: u32 = 0xFF7F7F7F; // 3D shadow
    pub const TITLE_ACTIVE: u32 = 0xFFE6E6E6; // Active window titlebar
    pub const TITLE_INACTIVE: u32 = 0xFFA0A0A0; // Inactive window titlebar
    pub const TEXT_BLACK: u32 = 0xFF000000;
    pub const TEXT_MUTED: u32 = 0xFF666666;
    pub const ACORN_RED: u32 = 0xFFD42B2B; // Close box and accent
    pub const BORDER_OUTLINE: u32 = 0xFF000000; // Outer window border
    pub const WIREFRAME: u32 = 0xFF000000; // Rubber-band drag outline
    pub const POINTER_CYAN: u32 = 0xFF00F3FF; // Day-glow blue
    pub const POINTER_BLUE: u32 = 0xFF021CA1; // Midnight blue
};

pub const Point = struct {
    x: i32,
    y: i32,
};

pub const Box = struct {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,

    pub fn fromPosSize(x: i32, y: i32, w: u32, h: u32) Box {
        return .{
            .x0 = x,
            .y0 = y,
            .x1 = x + @as(i32, @intCast(w)),
            .y1 = y + @as(i32, @intCast(h)),
        };
    }

    pub fn width(self: Box) u32 {
        return if (self.x1 > self.x0) @intCast(self.x1 - self.x0) else 0;
    }

    pub fn height(self: Box) u32 {
        return if (self.y1 > self.y0) @intCast(self.y1 - self.y0) else 0;
    }

    pub fn isEmpty(self: Box) bool {
        return self.x0 >= self.x1 or self.y0 >= self.y1;
    }

    pub fn contains(self: Box, px: i32, py: i32) bool {
        return px >= self.x0 and px < self.x1 and py >= self.y0 and py < self.y1;
    }

    pub fn containsPoint(self: Box, p: Point) bool {
        return self.contains(p.x, p.y);
    }

    pub fn containsBox(self: Box, other: Box) bool {
        return self.x0 <= other.x0 and self.x1 >= other.x1 and self.y0 <= other.y0 and self.y1 >= other.y1;
    }

    pub fn intersection(a: Box, b: Box) ?Box {
        const x0 = @max(a.x0, b.x0);
        const y0 = @max(a.y0, b.y0);
        const x1 = @min(a.x1, b.x1);
        const y1 = @min(a.y1, b.y1);
        if (x0 >= x1 or y0 >= y1) return null;
        return Box{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 };
    }

    pub fn unionWith(a: Box, b: Box) Box {
        if (a.width() == 0 or a.isEmpty()) return b;
        if (b.width() == 0 or b.isEmpty()) return a;
        return .{
            .x0 = @min(a.x0, b.x0),
            .y0 = @min(a.y0, b.y0),
            .x1 = @max(a.x1, b.x1),
            .y1 = @max(a.y1, b.y1),
        };
    }

    pub fn merge(a: *Box, b: Box) bool {
        if (a.y0 == b.y0 and a.y1 == b.y1 and a.x0 <= b.x1 and b.x0 <= a.x1) {
            a.x0 = @min(a.x0, b.x0);
            a.x1 = @max(a.x1, b.x1);
            return true;
        }
        if (a.x0 == b.x0 and a.x1 == b.x1 and a.y0 <= b.y1 and b.y0 <= a.y1) {
            a.y0 = @min(a.y0, b.y0);
            a.y1 = @max(a.y1, b.y1);
            return true;
        }
        return false;
    }

    // box_subtract_into from wuss: produces up to 4 non-overlapping slivers covering piece \ other
    pub fn subtract(piece: Box, other: Box, out: *[4]Box) usize {
        if (piece.width() == 0 or piece.height() == 0 or piece.isEmpty()) return 0;
        const maybe_cut = piece.intersection(other);
        if (maybe_cut == null) {
            out[0] = piece;
            return 1;
        }
        const cut = maybe_cut.?;
        var count: usize = 0;
        // Top band
        if (cut.y0 > piece.y0) {
            out[count] = .{ .x0 = piece.x0, .y0 = piece.y0, .x1 = piece.x1, .y1 = cut.y0 };
            count += 1;
        }
        // Bottom band
        if (cut.y1 < piece.y1) {
            out[count] = .{ .x0 = piece.x0, .y0 = cut.y1, .x1 = piece.x1, .y1 = piece.y1 };
            count += 1;
        }
        // Left band (vertically bounded by cut)
        if (cut.x0 > piece.x0) {
            out[count] = .{ .x0 = piece.x0, .y0 = cut.y0, .x1 = cut.x0, .y1 = cut.y1 };
            count += 1;
        }
        // Right band (vertically bounded by cut)
        if (cut.x1 < piece.x1) {
            out[count] = .{ .x0 = cut.x1, .y0 = cut.y0, .x1 = piece.x1, .y1 = cut.y1 };
            count += 1;
        }
        return count;
    }

    pub fn subtractInto(piece: Box, cut: Box, out: *[4]Box) usize {
        return subtract(piece, cut, out);
    }
};

// Subtract an array of occluding boxes from whole, returning disjoint surviving pieces
pub fn subtractBoxes(whole: Box, cuts: []const Box, out: *[32]Box) usize {
    var cur_buf: [32]Box = undefined;
    var nxt_buf: [32]Box = undefined;
    var cur = &cur_buf;
    var nxt = &nxt_buf;

    cur[0] = whole;
    var ncur: usize = 1;

    for (cuts) |cut_box| {
        var nnext: usize = 0;
        for (cur[0..ncur]) |piece| {
            var slivers: [4]Box = undefined;
            const sc = piece.subtract(cut_box, &slivers);
            for (slivers[0..sc]) |sl| {
                if (nnext < 32) {
                    nxt[nnext] = sl;
                    nnext += 1;
                }
            }
        }
        ncur = nnext;
        const tmp = cur;
        cur = nxt;
        nxt = tmp;
        if (ncur == 0) break;
    }

    @memcpy(out[0..ncur], cur[0..ncur]);
    return ncur;
}

pub const Rect = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,

    pub fn toBox(self: Rect) Box {
        return Box.fromPosSize(self.x, self.y, self.width, self.height);
    }

    pub fn contains(self: Rect, px: i32, py: i32) bool {
        return px >= self.x and px < self.x + @as(i32, @intCast(self.width)) and
            py >= self.y and py < self.y + @as(i32, @intCast(self.height));
    }

    pub fn unionWith(self: Rect, other: Rect) Rect {
        if (self.width == 0 or self.height == 0) return other;
        if (other.width == 0 or other.height == 0) return self;
        const min_x = @min(self.x, other.x);
        const min_y = @min(self.y, other.y);
        const max_x = @max(self.x + @as(i32, @intCast(self.width)), other.x + @as(i32, @intCast(other.width)));
        const max_y = @max(self.y + @as(i32, @intCast(self.height)), other.y + @as(i32, @intCast(other.height)));
        return Rect{
            .x = min_x,
            .y = min_y,
            .width = @intCast(@max(0, max_x - min_x)),
            .height = @intCast(@max(0, max_y - min_y)),
        };
    }
};

pub const DamageTracker = struct {
    boxes: [16]Box = undefined,
    count: usize = 0,
    total_damage: ?Box = null,

    pub fn markDirty(self: *DamageTracker, box: Box) void {
        if (box.isEmpty() or box.width() == 0 or box.height() == 0) return;
        if (self.total_damage) |td| {
            self.total_damage = td.unionWith(box);
        } else {
            self.total_damage = box;
        }

        var cur = box;
        var changed = true;
        while (changed) {
            changed = false;
            var i: usize = 0;
            while (i < self.count) : (i += 1) {
                if (self.boxes[i].containsBox(cur)) return;
                if (cur.containsBox(self.boxes[i]) or cur.merge(self.boxes[i])) {
                    self.count -= 1;
                    self.boxes[i] = self.boxes[self.count];
                    changed = true;
                    break;
                }
            }
        }
        if (self.count < 16) {
            self.boxes[self.count] = cur;
            self.count += 1;
        } else {
            self.boxes[15] = self.boxes[15].unionWith(cur);
        }
    }

    pub fn markAll(self: *DamageTracker, w: u32, h: u32) void {
        self.count = 0;
        self.markDirty(Box.fromPosSize(0, 0, w, h));
    }

    pub fn consume(self: *DamageTracker) ?Box {
        const d = self.total_damage;
        self.total_damage = null;
        self.count = 0;
        return d;
    }
};

pub const Surface = struct {
    width: u32,
    height: u32,
    stride: u32, // bytes per row
    pixels: []u32,
    clip: ?Box = null,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !Surface {
        const pixel_count = width * height;
        const pixels = try allocator.alloc(u32, pixel_count);
        @memset(pixels, Color.DESKTOP_BG);
        return Surface{
            .width = width,
            .height = height,
            .stride = width * 4,
            .pixels = pixels,
            .clip = null,
        };
    }

    pub fn deinit(self: *Surface, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }

    pub fn setClip(self: *Surface, maybe_clip: ?Box) void {
        self.clip = maybe_clip;
    }

    pub fn resetClip(self: *Surface) void {
        self.clip = null;
    }

    pub fn clear(self: *Surface, color: u32) void {
        if (self.clip) |c| {
            self.fillBox(c, color);
        } else {
            @memset(self.pixels, color);
        }
    }

    pub fn setPixel(self: *Surface, x: i32, y: i32, color: u32) void {
        if (x < 0 or y < 0 or x >= self.width or y >= self.height) return;
        if (self.clip) |c| {
            if (!c.contains(x, y)) return;
        }
        const idx = @as(usize, @intCast(y)) * self.width + @as(usize, @intCast(x));
        self.pixels[idx] = color;
    }

    pub fn fillBox(self: *Surface, box: Box, color: u32) void {
        var b = box;
        if (self.clip) |c| {
            b = b.intersection(c) orelse return;
        }
        const x0 = @max(0, b.x0);
        const y0 = @max(0, b.y0);
        const x1 = @min(@as(i32, @intCast(self.width)), b.x1);
        const y1 = @min(@as(i32, @intCast(self.height)), b.y1);
        if (x0 >= x1 or y0 >= y1) return;

        const copy_w = @as(usize, @intCast(x1 - x0));
        var y = y0;
        while (y < y1) : (y += 1) {
            const row_offset = @as(usize, @intCast(y)) * self.width + @as(usize, @intCast(x0));
            @memset(self.pixels[row_offset .. row_offset + copy_w], color);
        }
    }

    pub fn fillRect(self: *Surface, rect: Rect, color: u32) void {
        self.fillBox(rect.toBox(), color);
    }

    pub fn copyBoxFrom(self: *Surface, src: *const Surface, box: Box) void {
        var b = box;
        if (self.clip) |c| {
            b = b.intersection(c) orelse return;
        }
        const x0 = @max(0, b.x0);
        const y0 = @max(0, b.y0);
        const x1 = @min(@min(@as(i32, @intCast(self.width)), @as(i32, @intCast(src.width))), b.x1);
        const y1 = @min(@min(@as(i32, @intCast(self.height)), @as(i32, @intCast(src.height))), b.y1);
        if (x0 >= x1 or y0 >= y1) return;

        const copy_w = @as(usize, @intCast(x1 - x0));
        var y = y0;
        while (y < y1) : (y += 1) {
            const dst_off = @as(usize, @intCast(y)) * self.width + @as(usize, @intCast(x0));
            const src_off = @as(usize, @intCast(y)) * src.width + @as(usize, @intCast(x0));
            @memcpy(self.pixels[dst_off .. dst_off + copy_w], src.pixels[src_off .. src_off + copy_w]);
        }
    }

    pub fn copyRectFrom(self: *Surface, src: *const Surface, rect: Rect) void {
        self.copyBoxFrom(src, rect.toBox());
    }

    // Move rectangle within the same surface (equivalent to screen_copy_rect from wuss)
    pub fn copyBoxWithin(self: *Surface, src: Box, dst_x: i32, dst_y: i32) ?Box {
        const scr_box = Box.fromPosSize(0, 0, self.width, self.height);
        const clip_box = if (self.clip) |c| (c.intersection(scr_box) orelse return null) else scr_box;

        const dx = dst_x - src.x0;
        const dy = dst_y - src.y0;

        var s = clip_box.intersection(src) orelse return null;
        const d = Box{
            .x0 = s.x0 + dx,
            .y0 = s.y0 + dy,
            .x1 = s.x1 + dx,
            .y1 = s.y1 + dy,
        };
        const d_clipped = clip_box.intersection(d) orelse return null;

        s.x0 += d_clipped.x0 - d.x0;
        s.x1 += d_clipped.x1 - d.x1;
        s.y0 += d_clipped.y0 - d.y0;
        s.y1 += d_clipped.y1 - d.y1;

        if (s.x0 >= s.x1 or s.y0 >= s.y1) return null;

        const width = @as(usize, @intCast(s.x1 - s.x0));
        const height = @as(usize, @intCast(s.y1 - s.y0));

        if (dy > 0) {
            var row: isize = @as(isize, @intCast(height)) - 1;
            while (row >= 0) : (row -= 1) {
                const dst_off = @as(usize, @intCast(@as(isize, @intCast(d_clipped.y0)) + row)) * self.width + @as(usize, @intCast(d_clipped.x0));
                const src_off = @as(usize, @intCast(@as(isize, @intCast(s.y0)) + row)) * self.width + @as(usize, @intCast(s.x0));
                if (d_clipped.x0 > s.x0) {
                    std.mem.copyBackwards(u32, self.pixels[dst_off .. dst_off + width], self.pixels[src_off .. src_off + width]);
                } else {
                    std.mem.copyForwards(u32, self.pixels[dst_off .. dst_off + width], self.pixels[src_off .. src_off + width]);
                }
            }
        } else {
            var row: usize = 0;
            while (row < height) : (row += 1) {
                const dst_off = (@as(usize, @intCast(d_clipped.y0)) + row) * self.width + @as(usize, @intCast(d_clipped.x0));
                const src_off = (@as(usize, @intCast(s.y0)) + row) * self.width + @as(usize, @intCast(s.x0));
                if (d_clipped.x0 > s.x0) {
                    std.mem.copyBackwards(u32, self.pixels[dst_off .. dst_off + width], self.pixels[src_off .. src_off + width]);
                } else {
                    std.mem.copyForwards(u32, self.pixels[dst_off .. dst_off + width], self.pixels[src_off .. src_off + width]);
                }
            }
        }

        return d_clipped;
    }

    pub fn drawRectOutline(self: *Surface, rect: Rect, thickness: u32, color: u32) void {
        self.drawBoxOutline(rect.toBox(), thickness, color);
    }

    pub fn drawBoxOutline(self: *Surface, box: Box, thickness: u32, color: u32) void {
        const t = @as(i32, @intCast(thickness));
        // Top
        self.fillBox(.{ .x0 = box.x0, .y0 = box.y0, .x1 = box.x1, .y1 = box.y0 + t }, color);
        // Bottom
        self.fillBox(.{ .x0 = box.x0, .y0 = box.y1 - t, .x1 = box.x1, .y1 = box.y1 }, color);
        // Left
        self.fillBox(.{ .x0 = box.x0, .y0 = box.y0, .x1 = box.x0 + t, .y1 = box.y1 }, color);
        // Right
        self.fillBox(.{ .x0 = box.x1 - t, .y0 = box.y0, .x1 = box.x1, .y1 = box.y1 }, color);
    }

    // Classic Acorn RISC OS 3D bevel box
    pub fn drawBevelBox(self: *Surface, rect: Rect, light_col: u32, dark_col: u32, is_inset: bool) void {
        self.drawBevel(rect.toBox(), light_col, dark_col, is_inset);
    }

    pub fn drawBevel(self: *Surface, box: Box, light_col: u32, dark_col: u32, is_inset: bool) void {
        const top_left = if (is_inset) dark_col else light_col;
        const bot_right = if (is_inset) light_col else dark_col;

        // Top line
        self.fillBox(.{ .x0 = box.x0, .y0 = box.y0, .x1 = box.x1, .y1 = box.y0 + 1 }, top_left);
        // Left line
        self.fillBox(.{ .x0 = box.x0, .y0 = box.y0, .x1 = box.x0 + 1, .y1 = box.y1 }, top_left);
        // Bottom line
        self.fillBox(.{ .x0 = box.x0, .y0 = box.y1 - 1, .x1 = box.x1, .y1 = box.y1 }, bot_right);
        // Right line
        self.fillBox(.{ .x0 = box.x1 - 1, .y0 = box.y0, .x1 = box.x1, .y1 = box.y1 }, bot_right);
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
        if (fb_path.len >= z_path.len) return error.NameTooLong;
        @memcpy(z_path[0..fb_path.len], fb_path);
        z_path[fb_path.len] = 0;

        const open_rc = linux.open(@ptrCast(&z_path), .{ .ACCMODE = .RDWR }, 0);
        const signed_rc: isize = @bitCast(open_rc);
        if (signed_rc < 0) {
            // Fallback to virtual 1024x768 surface for headless testing
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
        }
        const fd: i32 = @intCast(signed_rc);

        // Query screen resolution from driver if available
        var w: u32 = 1280;
        var h: u32 = 800;

        const FbVarScreeninfo = extern struct {
            xres: u32,
            yres: u32,
            xres_virtual: u32,
            yres_virtual: u32,
            xoffset: u32,
            yoffset: u32,
            bits_per_pixel: u32,
            pad: [128]u8 = undefined,
        };

        var vinfo: FbVarScreeninfo = undefined;
        const FBIOGET_VSCREENINFO: usize = 0x4600;
        const ioctl_rc = linux.ioctl(fd, FBIOGET_VSCREENINFO, @intFromPtr(&vinfo));
        const signed_ioctl: isize = @bitCast(ioctl_rc);
        if (signed_ioctl == 0 and vinfo.xres > 0 and vinfo.yres > 0) {
            w = vinfo.xres;
            h = vinfo.yres;
        }

        const total_bytes = w * h * 4;

        const map_res = linux.mmap(
            null,
            total_bytes,
            linux.PROT{ .READ = true, .WRITE = true },
            linux.MAP{ .TYPE = .SHARED },
            fd,
            0,
        );
        const signed_map: isize = @bitCast(map_res);
        if (signed_map < 0) {
            _ = linux.close(fd);
            return error.MmapFailed;
        }

        const pixels: [*]u32 = @ptrFromInt(map_res);
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

    pub const MS_ASYNC: i32 = 1;

    pub fn flush(self: *FramebufferDevice) void {
        if (self.fb_fd >= 0) {
            _ = linux.msync(@ptrCast(self.mapped_mem.ptr), self.mapped_mem.len * 4, MS_ASYNC);
        }
    }

    pub fn swapDamage(self: *FramebufferDevice, maybe_damage: ?Box) void {
        const dmg = maybe_damage orelse return;
        self.screen_surface.copyBoxFrom(&self.backbuffer, dmg);
        self.flush();
    }

    pub fn swapBuffers(self: *FramebufferDevice) void {
        self.swapDamage(Box.fromPosSize(0, 0, self.width, self.height));
    }

    // Suppress blinking VT text console cursor over graphics surface
    pub fn disableConsoleCursor() void {
        const tty_paths = [_][]const u8{ "/dev/tty0", "/dev/tty1", "/dev/console" };
        for (tty_paths) |p| {
            var z: [64]u8 = undefined;
            @memcpy(z[0..p.len], p);
            z[p.len] = 0;
            const fd_res = linux.open(@ptrCast(&z), .{ .ACCMODE = .RDWR }, 0);
            const signed_fd: isize = @bitCast(fd_res);
            if (signed_fd >= 0) {
                const fd: i32 = @intCast(signed_fd);
                // Hide cursor escape code: \x1b[?25l
                const hide_code = "\x1b[?25l";
                _ = linux.write(fd, hide_code.ptr, hide_code.len);
                // KDSETMODE = 0x4B3A, KD_GRAPHICS = 1
                _ = linux.ioctl(fd, 0x4B3A, 1);
                _ = linux.close(fd);
                break;
            }
        }

        const fbcon_paths = [_][]const u8{
            "/sys/class/graphics/fbcon/cursor_blink",
            "/sys/devices/virtual/graphics/fbcon/cursor_blink",
        };
        for (fbcon_paths) |p| {
            var z: [64]u8 = undefined;
            @memcpy(z[0..p.len], p);
            z[p.len] = 0;
            const fd_res = linux.open(@ptrCast(&z), .{ .ACCMODE = .WRONLY }, 0);
            const signed_fd: isize = @bitCast(fd_res);
            if (signed_fd >= 0) {
                const fd: i32 = @intCast(signed_fd);
                _ = linux.write(fd, "0", 1);
                _ = linux.close(fd);
            }
        }
    }
};

test "framebuffer: box and damage tracker" {
    const testing = std.testing;
    const b1 = Box.fromPosSize(10, 10, 50, 50);
    const b2 = Box.fromPosSize(40, 40, 50, 50);
    const u = b1.unionWith(b2);
    try testing.expectEqual(@as(i32, 10), u.x0);
    try testing.expectEqual(@as(i32, 10), u.y0);
    try testing.expectEqual(@as(i32, 90), u.x1);
    try testing.expectEqual(@as(i32, 90), u.y1);
    try testing.expectEqual(@as(u32, 80), u.width());
    try testing.expectEqual(@as(u32, 80), u.height());

    // Test box subtraction (wuss box_subtract_into)
    const cut = b1.intersection(b2).?;
    var slivers: [4]Box = undefined;
    const count = Box.subtractInto(b1, cut, &slivers);
    try testing.expect(count > 0);

    var dt = DamageTracker{};
    dt.markDirty(b1);
    dt.markDirty(b2);
    const consumed = dt.consume();
    try testing.expect(consumed != null);
    try testing.expectEqual(u.width(), consumed.?.width());
    try testing.expect(dt.consume() == null);
}

test "framebuffer: surface bevel and copy" {
    const testing = std.testing;
    var s1 = try Surface.init(testing.allocator, 100, 100);
    defer s1.deinit(testing.allocator);
    var s2 = try Surface.init(testing.allocator, 100, 100);
    defer s2.deinit(testing.allocator);

    s1.drawBevelBox(.{ .x = 10, .y = 10, .width = 20, .height = 20 }, Color.BEVEL_LIGHT, Color.BEVEL_DARK, false);
    s2.copyRectFrom(&s1, .{ .x = 10, .y = 10, .width = 20, .height = 20 });
    try testing.expectEqual(s1.pixels[10 * 100 + 10], s2.pixels[10 * 100 + 10]);
}

