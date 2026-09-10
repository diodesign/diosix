// Wayland Translation Bridge for Diosix Window Manager (diosix-wm)
// Implements core Wayland protocols (wl_compositor, wl_shm, xdg_shell, wl_seat)
// enabling native and foreign guest applications (from Debian/Linux) to display
// seamless windows on the Diosix RISC OS-style desktop.

const std = @import("std");
const linux = std.os.linux;
const fb = @import("framebuffer.zig");
const font = @import("font.zig");
const win_mod = @import("window.zig");
const wm_mod = @import("wm.zig");

// Standard Wayland Protocol IDs & Constants
pub const WL_DISPLAY_ID: u32 = 1;

pub const WL_SHM_FORMAT_ARGB8888: u32 = 0;
pub const WL_SHM_FORMAT_XRGB8888: u32 = 1;

pub const MAX_WAYLAND_CLIENTS: usize = 16;
pub const MAX_OBJECTS_PER_CLIENT: usize = 256;
pub const MAX_WAYLAND_WINDOWS: usize = 32;

pub const ObjectType = enum {
    none,
    display,
    registry,
    compositor,
    shm,
    shm_pool,
    buffer,
    surface,
    xdg_wm_base,
    xdg_surface,
    xdg_toplevel,
    seat,
    pointer,
    keyboard,
    callback,
};

pub const Object = struct {
    id: u32 = 0,
    obj_type: ObjectType = .none,
    data_idx: usize = 0,
};

pub const ShmPool = struct {
    id: u32 = 0,
    size: usize = 0,
    data: ?[*]u8 = null,
    fd: i32 = -1,
};

pub const Buffer = struct {
    id: u32 = 0,
    pool_id: u32 = 0,
    offset: usize = 0,
    width: u32 = 0,
    height: u32 = 0,
    stride: u32 = 0,
    format: u32 = 0,
};

pub const Surface = struct {
    id: u32 = 0,
    current_buffer_id: u32 = 0,
    pending_buffer_id: u32 = 0,
    xdg_surface_id: u32 = 0,
    xdg_toplevel_id: u32 = 0,
    frame_callback_id: u32 = 0,

    title: [64]u8 = @splat(0),
    title_len: usize = 0,
    app_id: [64]u8 = @splat(0),
    app_id_len: usize = 0,

    width: u32 = 0,
    height: u32 = 0,

    window_ptr: ?*win_mod.Window = null,
    client_idx: usize = 0,
};

pub const WaylandClient = struct {
    allocator: std.mem.Allocator,
    sock_fd: i32 = -1,
    is_active: bool = false,

    objects: [MAX_OBJECTS_PER_CLIENT]Object = @splat(.{}),
    object_count: usize = 0,

    pools: [16]ShmPool = @splat(.{}),
    pool_count: usize = 0,

    buffers: [32]Buffer = @splat(.{}),
    buffer_count: usize = 0,

    surfaces: [16]Surface = @splat(.{}),
    surface_count: usize = 0,

    in_buf: [16384]u8 = @splat(0),
    in_len: usize = 0,

    out_buf: [16384]u8 = @splat(0),
    out_len: usize = 0,

    next_serial: u32 = 1,

    pub fn init(allocator: std.mem.Allocator, fd: i32) WaylandClient {
        var client = WaylandClient{
            .allocator = allocator,
            .sock_fd = fd,
            .is_active = true,
        };
        // Object 1 is wl_display by specification
        client.addObject(WL_DISPLAY_ID, .display, 0);
        return client;
    }

    pub fn deinit(self: *WaylandClient) void {
        if (self.sock_fd >= 0) {
            _ = linux.close(self.sock_fd);
            self.sock_fd = -1;
        }
        for (self.pools[0..self.pool_count]) |*p| {
            if (p.data) |ptr| {
                _ = linux.munmap(ptr, p.size);
                p.data = null;
            }
            if (p.fd >= 0) {
                _ = linux.close(p.fd);
                p.fd = -1;
            }
        }
        self.is_active = false;
    }

    pub fn addObject(self: *WaylandClient, id: u32, obj_type: ObjectType, data_idx: usize) void {
        for (self.objects[0..self.object_count]) |*obj| {
            if (obj.id == id) {
                obj.obj_type = obj_type;
                obj.data_idx = data_idx;
                return;
            }
        }
        if (self.object_count < MAX_OBJECTS_PER_CLIENT) {
            self.objects[self.object_count] = .{
                .id = id,
                .obj_type = obj_type,
                .data_idx = data_idx,
            };
            self.object_count += 1;
        }
    }

    pub fn findObject(self: *const WaylandClient, id: u32) ?Object {
        for (self.objects[0..self.object_count]) |obj| {
            if (obj.id == id) return obj;
        }
        return null;
    }

    pub fn removeObject(self: *WaylandClient, id: u32) void {
        var i: usize = 0;
        while (i < self.object_count) : (i += 1) {
            if (self.objects[i].id == id) {
                self.objects[i] = self.objects[self.object_count - 1];
                self.object_count -= 1;
                return;
            }
        }
    }

    pub fn sendEvent(self: *WaylandClient, obj_id: u32, opcode: u16, payload: []const u8) void {
        const total_size: u16 = @intCast(8 + payload.len);
        if (self.out_len + total_size > self.out_buf.len) return;

        // 8-byte header: object_id (u32), size_and_opcode (size: u16 << 16 | opcode: u16)
        std.mem.writeInt(u32, self.out_buf[self.out_len..][0..4], obj_id, .little);
        std.mem.writeInt(u16, self.out_buf[self.out_len + 4 ..][0..2], opcode, .little);
        std.mem.writeInt(u16, self.out_buf[self.out_len + 6 ..][0..2], total_size, .little);
        self.out_len += 8;

        if (payload.len > 0) {
            @memcpy(self.out_buf[self.out_len .. self.out_len + payload.len], payload);
            self.out_len += payload.len;
        }
    }

    pub fn flush(self: *WaylandClient) void {
        if (self.out_len == 0 or self.sock_fd < 0) return;
        const w = linux.write(self.sock_fd, @ptrCast(&self.out_buf), self.out_len);
        const signed_w: isize = @bitCast(w);
        if (signed_w > 0) {
            const written = @as(usize, @intCast(signed_w));
            if (written < self.out_len) {
                const rem = self.out_len - written;
                std.mem.copyForwards(u8, self.out_buf[0..rem], self.out_buf[written .. written + rem]);
                self.out_len = rem;
            } else {
                self.out_len = 0;
            }
        }
    }

    pub fn handleRead(self: *WaylandClient, wm: *wm_mod.WindowManager) void {
        if (self.sock_fd < 0) return;

        // Use recvmsg to allow receiving shared memory file descriptors via SCM_RIGHTS
        var iov = [1]std.posix.iovec{.{
            .base = self.in_buf[self.in_len..].ptr,
            .len = self.in_buf.len - self.in_len,
        }};

        var cmsg_buf: [128]u8 align(@alignOf(linux.cmsghdr)) = @splat(0);
        var msg = linux.msghdr{
            .name = null,
            .namelen = 0,
            .iov = &iov,
            .iovlen = 1,
            .control = &cmsg_buf,
            .controllen = cmsg_buf.len,
            .flags = 0,
        };

        const rc = linux.recvmsg(self.sock_fd, &msg, 0);
        const signed_rc: isize = @bitCast(rc);
        if (signed_rc <= 0) {
            self.deinit();
            return;
        }

        const bytes_read = @as(usize, @intCast(signed_rc));
        self.in_len += bytes_read;

        // Extract received file descriptor if present
        var passed_fd: i32 = -1;
        if (msg.controllen >= @sizeOf(linux.cmsghdr)) {
            const ch: *const linux.cmsghdr = @ptrCast(@alignCast(&cmsg_buf));
            if (ch.level == 1 and ch.type == 0x01) { // SOL_SOCKET = 1, SCM_RIGHTS = 0x01
                const data_ptr = @as([*]const u8, @ptrCast(ch)) + @sizeOf(linux.cmsghdr);
                const fd_ptr: *const i32 = @ptrCast(@alignCast(data_ptr));
                passed_fd = fd_ptr.*;
            }
        }

        // Process discrete Wayland wire messages
        var offset: usize = 0;
        while (offset + 8 <= self.in_len) {
            const obj_id = std.mem.readInt(u32, self.in_buf[offset..][0..4], .little);
            const opcode = std.mem.readInt(u16, self.in_buf[offset + 4 ..][0..2], .little);
            const msg_size = std.mem.readInt(u16, self.in_buf[offset + 6 ..][0..2], .little);

            if (msg_size < 8 or offset + msg_size > self.in_len) break;

            const payload = self.in_buf[offset + 8 .. offset + msg_size];
            self.dispatchMessage(obj_id, opcode, payload, passed_fd, wm);
            passed_fd = -1; // Consumed

            offset += msg_size;
        }

        // Compact unconsumed bytes
        if (offset > 0) {
            const rem = self.in_len - offset;
            if (rem > 0) {
                std.mem.copyForwards(u8, self.in_buf[0..rem], self.in_buf[offset .. offset + rem]);
            }
            self.in_len = rem;
        }

        self.flush();
    }

    fn dispatchMessage(self: *WaylandClient, obj_id: u32, opcode: u16, payload: []const u8, passed_fd: i32, wm: *wm_mod.WindowManager) void {
        const obj = self.findObject(obj_id) orelse return;

        switch (obj.obj_type) {
            .display => {
                if (opcode == 0) { // sync(callback_id: new_id)
                    if (payload.len >= 4) {
                        const cb_id = std.mem.readInt(u32, payload[0..4], .little);
                        // Send wl_callback.done(serial)
                        var done_arg: [4]u8 = undefined;
                        std.mem.writeInt(u32, &done_arg, self.next_serial, .little);
                        self.next_serial += 1;
                        self.sendEvent(cb_id, 0, &done_arg);
                        self.removeObject(cb_id);
                    }
                } else if (opcode == 1) { // get_registry(registry_id: new_id)
                    if (payload.len >= 4) {
                        const reg_id = std.mem.readInt(u32, payload[0..4], .little);
                        self.addObject(reg_id, .registry, 0);

                        // Broadcast core Wayland globals
                        self.sendGlobal(reg_id, 1, "wl_compositor", 4);
                        self.sendGlobal(reg_id, 2, "wl_shm", 1);
                        self.sendGlobal(reg_id, 3, "wl_seat", 5);
                        self.sendGlobal(reg_id, 4, "xdg_wm_base", 2);
                    }
                }
            },
            .registry => {
                if (opcode == 0) { // bind(name, interface, version, id)
                    if (payload.len >= 12) {
                        const name = std.mem.readInt(u32, payload[0..4], .little);
                        const iface_len = std.mem.readInt(u32, payload[4..8], .little);
                        const iface_pad = (iface_len + 3) & ~@as(u32, 3);
                        const id_offset = 8 + iface_pad + 4; // after iface string + version
                        if (id_offset + 4 <= payload.len) {
                            const new_id = std.mem.readInt(u32, payload[id_offset..][0..4], .little);
                            switch (name) {
                                1 => self.addObject(new_id, .compositor, 0),
                                2 => {
                                    self.addObject(new_id, .shm, 0);
                                    // Send supported formats: ARGB8888 (0), XRGB8888 (1)
                                    var fmt_arg: [4]u8 = undefined;
                                    std.mem.writeInt(u32, &fmt_arg, WL_SHM_FORMAT_XRGB8888, .little);
                                    self.sendEvent(new_id, 0, &fmt_arg);
                                    std.mem.writeInt(u32, &fmt_arg, WL_SHM_FORMAT_ARGB8888, .little);
                                    self.sendEvent(new_id, 0, &fmt_arg);
                                },
                                3 => {
                                    self.addObject(new_id, .seat, 0);
                                    var cap_arg: [4]u8 = undefined;
                                    std.mem.writeInt(u32, &cap_arg, 3, .little); // Pointer (1) | Keyboard (2)
                                    self.sendEvent(new_id, 0, &cap_arg);
                                    self.sendStringEvent(new_id, 1, "seat0");
                                },
                                4 => self.addObject(new_id, .xdg_wm_base, 0),
                                else => {},
                            }
                        }
                    }
                }
            },
            .compositor => {
                if (opcode == 0) { // create_surface(id: new_id)
                    if (payload.len >= 4 and self.surface_count < self.surfaces.len) {
                        const surf_id = std.mem.readInt(u32, payload[0..4], .little);
                        const idx = self.surface_count;
                        self.surfaces[idx] = Surface{
                            .id = surf_id,
                            .width = 640,
                            .height = 480,
                        };
                        self.surface_count += 1;
                        self.addObject(surf_id, .surface, idx);
                    }
                }
            },
            .shm => {
                if (opcode == 0) { // create_pool(id: new_id, fd, size: int)
                    if (payload.len >= 8 and self.pool_count < self.pools.len) {
                        const pool_id = std.mem.readInt(u32, payload[0..4], .little);
                        const size_val = std.mem.readInt(i32, payload[4..8], .little);
                        const pool_size = if (size_val > 0) @as(usize, @intCast(size_val)) else 0;

                        var pool_ptr: ?[*]u8 = null;
                        if (passed_fd >= 0 and pool_size > 0) {
                            const mmap_res = linux.mmap(null, pool_size, linux.PROT{ .READ = true, .WRITE = true }, linux.MAP{ .TYPE = .SHARED }, passed_fd, 0);
                            const signed_mmap: isize = @bitCast(mmap_res);
                            if (signed_mmap > 0) {
                                pool_ptr = @ptrFromInt(@as(usize, @intCast(signed_mmap)));
                            }
                        }

                        const p_idx = self.pool_count;
                        self.pools[p_idx] = ShmPool{
                            .id = pool_id,
                            .size = pool_size,
                            .data = pool_ptr,
                            .fd = passed_fd,
                        };
                        self.pool_count += 1;
                        self.addObject(pool_id, .shm_pool, p_idx);
                    }
                }
            },
            .shm_pool => {
                if (opcode == 0) { // create_buffer(id: new_id, offset, width, height, stride, format)
                    if (payload.len >= 24 and self.buffer_count < self.buffers.len) {
                        const buf_id = std.mem.readInt(u32, payload[0..4], .little);
                        const offset = std.mem.readInt(i32, payload[4..8], .little);
                        const width = std.mem.readInt(i32, payload[8..12], .little);
                        const height = std.mem.readInt(i32, payload[12..16], .little);
                        const stride = std.mem.readInt(i32, payload[16..20], .little);
                        const format = std.mem.readInt(u32, payload[20..24], .little);

                        const b_idx = self.buffer_count;
                        self.buffers[b_idx] = Buffer{
                            .id = buf_id,
                            .pool_id = obj_id,
                            .offset = if (offset > 0) @intCast(offset) else 0,
                            .width = if (width > 0) @intCast(width) else 0,
                            .height = if (height > 0) @intCast(height) else 0,
                            .stride = if (stride > 0) @intCast(stride) else 0,
                            .format = format,
                        };
                        self.buffer_count += 1;
                        self.addObject(buf_id, .buffer, b_idx);
                    }
                }
            },
            .surface => {
                const s_idx = obj.data_idx;
                if (s_idx < self.surface_count) {
                    const surf = &self.surfaces[s_idx];
                    if (opcode == 1) { // attach(buffer, x, y)
                        if (payload.len >= 4) {
                            surf.pending_buffer_id = std.mem.readInt(u32, payload[0..4], .little);
                        }
                    } else if (opcode == 3) { // frame(callback_id)
                        if (payload.len >= 4) {
                            surf.frame_callback_id = std.mem.readInt(u32, payload[0..4], .little);
                            self.addObject(surf.frame_callback_id, .callback, 0);
                        }
                    } else if (opcode == 6) { // commit()
                        surf.current_buffer_id = surf.pending_buffer_id;
                        self.commitSurface(surf, wm);

                        // Fire frame callback if registered
                        if (surf.frame_callback_id != 0) {
                            var time_arg: [4]u8 = undefined;
                            std.mem.writeInt(u32, &time_arg, self.next_serial, .little);
                            self.sendEvent(surf.frame_callback_id, 0, &time_arg);
                            self.removeObject(surf.frame_callback_id);
                            surf.frame_callback_id = 0;
                        }
                    }
                }
            },
            .xdg_wm_base => {
                if (opcode == 2) { // get_xdg_surface(id: new_id, surface_id)
                    if (payload.len >= 8) {
                        const xdg_id = std.mem.readInt(u32, payload[0..4], .little);
                        const s_id = std.mem.readInt(u32, payload[4..8], .little);
                        self.addObject(xdg_id, .xdg_surface, 0);

                        for (self.surfaces[0..self.surface_count]) |*s| {
                            if (s.id == s_id) s.xdg_surface_id = xdg_id;
                        }
                    }
                } else if (opcode == 3) { // pong(serial)
                    // Keepalive acknowledged
                }
            },
            .xdg_surface => {
                if (opcode == 1) { // get_toplevel(id: new_id)
                    if (payload.len >= 4) {
                        const top_id = std.mem.readInt(u32, payload[0..4], .little);
                        self.addObject(top_id, .xdg_toplevel, 0);

                        for (self.surfaces[0..self.surface_count]) |*s| {
                            if (s.xdg_surface_id == obj_id) s.xdg_toplevel_id = top_id;
                        }

                        // Send initial configure sequence
                        var conf_states = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 }; // width = 0, height = 0, states = empty
                        self.sendEvent(top_id, 0, &conf_states);

                        var serial_buf: [4]u8 = undefined;
                        std.mem.writeInt(u32, &serial_buf, self.next_serial, .little);
                        self.sendEvent(obj_id, 0, &serial_buf);
                        self.next_serial += 1;
                    }
                }
            },
            .xdg_toplevel => {
                if (opcode == 2) { // set_title(title: string)
                    if (payload.len >= 4) {
                        const str_len = std.mem.readInt(u32, payload[0..4], .little);
                        if (str_len > 1 and 4 + str_len <= payload.len) {
                            const actual_str = payload[4 .. 4 + str_len - 1]; // strip NUL
                            for (self.surfaces[0..self.surface_count]) |*s| {
                                if (s.xdg_toplevel_id == obj_id) {
                                    const c_len = @min(actual_str.len, s.title.len - 1);
                                    @memcpy(s.title[0..c_len], actual_str[0..c_len]);
                                    s.title[c_len] = 0;
                                    s.title_len = c_len;

                                    if (s.window_ptr) |win| {
                                        var full_title: [80]u8 = undefined;
                                        const t_str = std.fmt.bufPrint(&full_title, "[Wayland] {s}", .{s.title[0..s.title_len]}) catch s.title[0..s.title_len];
                                        win.setTitle(t_str);
                                    }
                                }
                            }
                        }
                    }
                } else if (opcode == 3) { // set_app_id
                    if (payload.len >= 4) {
                        const str_len = std.mem.readInt(u32, payload[0..4], .little);
                        if (str_len > 1 and 4 + str_len <= payload.len) {
                            const actual_str = payload[4 .. 4 + str_len - 1];
                            for (self.surfaces[0..self.surface_count]) |*s| {
                                if (s.xdg_toplevel_id == obj_id) {
                                    const c_len = @min(actual_str.len, s.app_id.len - 1);
                                    @memcpy(s.app_id[0..c_len], actual_str[0..c_len]);
                                    s.app_id[c_len] = 0;
                                    s.app_id_len = c_len;
                                }
                            }
                        }
                    }
                }
            },
            .seat => {
                if (opcode == 0) { // get_pointer(id)
                    if (payload.len >= 4) {
                        const ptr_id = std.mem.readInt(u32, payload[0..4], .little);
                        self.addObject(ptr_id, .pointer, 0);
                    }
                } else if (opcode == 1) { // get_keyboard(id)
                    if (payload.len >= 4) {
                        const kbd_id = std.mem.readInt(u32, payload[0..4], .little);
                        self.addObject(kbd_id, .keyboard, 0);
                    }
                }
            },
            else => {},
        }
    }

    fn sendGlobal(self: *WaylandClient, reg_id: u32, name: u32, iface: []const u8, version: u32) void {
        var buf: [128]u8 = undefined;
        std.mem.writeInt(u32, buf[0..4], name, .little);
        const s_len = @as(u32, @intCast(iface.len + 1));
        std.mem.writeInt(u32, buf[4..8], s_len, .little);
        @memcpy(buf[8 .. 8 + iface.len], iface);
        buf[8 + iface.len] = 0; // NUL terminator
        const padded_len = (iface.len + 1 + 3) & ~@as(usize, 3);
        const pad_zero_start = 8 + iface.len + 1;
        const pad_zero_end = 8 + padded_len;
        if (pad_zero_end > pad_zero_start) {
            @memset(buf[pad_zero_start..pad_zero_end], 0);
        }
        std.mem.writeInt(u32, buf[8 + padded_len ..][0..4], version, .little);
        self.sendEvent(reg_id, 0, buf[0 .. 8 + padded_len + 4]);
    }

    fn sendStringEvent(self: *WaylandClient, obj_id: u32, opcode: u16, str: []const u8) void {
        var buf: [128]u8 = undefined;
        const s_len = @as(u32, @intCast(str.len + 1));
        std.mem.writeInt(u32, buf[0..4], s_len, .little);
        @memcpy(buf[4 .. 4 + str.len], str);
        buf[4 + str.len] = 0;
        const padded = (str.len + 1 + 3) & ~@as(usize, 3);
        const p_start = 4 + str.len + 1;
        const p_end = 4 + padded;
        if (p_end > p_start) {
            @memset(buf[p_start..p_end], 0);
        }
        self.sendEvent(obj_id, opcode, buf[0 .. 4 + padded]);
    }

    fn commitSurface(self: *WaylandClient, surf: *Surface, wm: *wm_mod.WindowManager) void {
        // Find attached buffer
        var maybe_buf: ?Buffer = null;
        for (self.buffers[0..self.buffer_count]) |b| {
            if (b.id == surf.current_buffer_id) {
                maybe_buf = b;
                break;
            }
        }
        const b = maybe_buf orelse return;
        surf.width = b.width;
        surf.height = b.height;

        // If this surface has an xdg_toplevel and no Window exists, create one!
        if (surf.window_ptr == null and surf.xdg_toplevel_id != 0 and surf.width > 0 and surf.height > 0) {
            const task = win_mod.Task{
                .handle = waylandWindowTaskHandle,
                .task_data = surf,
                .bg = fb.Color.WINDOW_BG,
            };

            var title_buf: [80]u8 = undefined;
            const t_slice = if (surf.title_len > 0) surf.title[0..surf.title_len] else if (surf.app_id_len > 0) surf.app_id[0..surf.app_id_len] else "Application";
            const full_title = std.fmt.bufPrint(&title_buf, "[Wayland] {s}", .{t_slice}) catch t_slice;

            const win_w = @min(surf.width + 12, wm.scr_width - 30);
            const win_h = @min(surf.height + 40, wm.scr_height - 50);

            if (wm.createWindow(80, 80, win_w, win_h, full_title, win_mod.WindowFlags.none, task, surf.width, surf.height)) |w| {
                surf.window_ptr = w;
            } else |_| {}
        }

        // Blit buffer pixels into window if mapped
        if (surf.window_ptr) |win| {
            // Find shared memory pool
            var pool_data: ?[*]u8 = null;
            for (self.pools[0..self.pool_count]) |p| {
                if (p.id == b.pool_id) {
                    pool_data = p.data;
                    break;
                }
            }

            if (pool_data) |ptr| {
                const src_slice: [*]const u32 = @ptrCast(@alignCast(ptr + b.offset));
                const stride_pixels = b.stride / 4;

                // Redraw window damage
                win.invalidateAll();
                _ = src_slice;
                _ = stride_pixels;
            }
        }
    }
};

// Global Wayland Server managing client connections
pub const WaylandServer = struct {
    allocator: std.mem.Allocator,
    unix_fd: i32 = -1,
    tcp_fd: i32 = -1,

    clients: [MAX_WAYLAND_CLIENTS]?WaylandClient = @splat(null),

    pub fn init(allocator: std.mem.Allocator, unix_path: []const u8, tcp_port: u16) WaylandServer {
        var ws = WaylandServer{
            .allocator = allocator,
        };

        // 1. Setup AF_UNIX Wayland server socket (e.g. /tmp/wayland-0)
        _ = linux.unlink(@ptrCast(unix_path.ptr));
        const u_fd = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.NONBLOCK, 0);
        const signed_u: isize = @bitCast(u_fd);
        if (signed_u >= 0) {
            const fd: i32 = @intCast(signed_u);
            const SockaddrUn = extern struct {
                family: u16,
                path: [108]u8,
            };
            var sun = SockaddrUn{
                .family = linux.AF.UNIX,
                .path = @splat(0),
            };
            const c_len = @min(unix_path.len, sun.path.len - 1);
            @memcpy(sun.path[0..c_len], unix_path[0..c_len]);
            sun.path[c_len] = 0;

            if (linux.bind(fd, @ptrCast(&sun), @sizeOf(SockaddrUn)) == 0) {
                if (linux.listen(fd, 8) == 0) {
                    ws.unix_fd = fd;
                }
            }
        }

        // 2. Setup AF_INET TCP listening socket (e.g. 0.0.0.0:8484)
        const t_fd = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.NONBLOCK, 0);
        const signed_t: isize = @bitCast(t_fd);
        if (signed_t >= 0) {
            const fd: i32 = @intCast(signed_t);

            // Enable SO_REUSEADDR
            var opt_val: i32 = 1;
            _ = linux.setsockopt(fd, 1, 2, @ptrCast(&opt_val), @sizeOf(i32)); // SOL_SOCKET=1, SO_REUSEADDR=2

            const SockaddrIn = extern struct {
                family: u16,
                port: u16,
                addr: u32,
                zero: [8]u8 = @splat(0),
            };
            const port_be = @as(u16, (tcp_port >> 8) | (tcp_port << 8));
            const sin = SockaddrIn{
                .family = linux.AF.INET,
                .port = port_be,
                .addr = 0, // INADDR_ANY (0.0.0.0)
            };

            if (linux.bind(fd, @ptrCast(&sin), @sizeOf(SockaddrIn)) == 0) {
                if (linux.listen(fd, 8) == 0) {
                    ws.tcp_fd = fd;
                }
            }
        }

        return ws;
    }

    pub fn deinit(self: *WaylandServer) void {
        for (&self.clients) |*maybe_c| {
            if (maybe_c.*) |*c| {
                c.deinit();
                maybe_c.* = null;
            }
        }
        if (self.unix_fd >= 0) {
            _ = linux.close(self.unix_fd);
            self.unix_fd = -1;
        }
        if (self.tcp_fd >= 0) {
            _ = linux.close(self.tcp_fd);
            self.tcp_fd = -1;
        }
    }

    pub fn acceptNewClients(self: *WaylandServer) void {
        const listeners = [_]i32{ self.unix_fd, self.tcp_fd };
        for (listeners) |lfd| {
            if (lfd < 0) continue;
            while (true) {
                const client_fd = linux.accept4(lfd, null, null, linux.SOCK.NONBLOCK);
                const signed_cfd: isize = @bitCast(client_fd);
                if (signed_cfd < 0) break;
                const c_fd: i32 = @intCast(signed_cfd);

                var placed = false;
                for (&self.clients) |*slot| {
                    if (slot.* == null) {
                        slot.* = WaylandClient.init(self.allocator, c_fd);
                        placed = true;
                        break;
                    }
                }
                if (!placed) {
                    _ = linux.close(c_fd);
                }
            }
        }
    }

    pub fn pollAndProcess(self: *WaylandServer, wm: *wm_mod.WindowManager) void {
        self.acceptNewClients();

        for (&self.clients) |*slot| {
            if (slot.*) |*c| {
                if (c.is_active) {
                    c.handleRead(wm);
                } else {
                    c.deinit();
                    slot.* = null;
                }
            }
        }
    }
};

pub var global_wayland_server: ?WaylandServer = null;

pub fn waylandWindowTaskHandle(win: *win_mod.Window, ev: *const win_mod.Event, data_ptr: ?*anyopaque) anyerror!void {
    const surf = if (data_ptr) |p| @as(*Surface, @ptrCast(@alignCast(p))) else return;

    switch (ev.kind) {
        .redraw => {
            const surface = ev.data.redraw.surface;
            const bounds = ev.data.redraw.bounds;
            surface.setClip(bounds);

            // Draw window background
            surface.fillBox(bounds, fb.Color.WINDOW_BG);

            // If Wayland buffer is attached, blit content
            if (global_wayland_server) |*ws| {
                for (&ws.clients) |*slot| {
                    if (slot.*) |*c| {
                        for (c.buffers[0..c.buffer_count]) |b| {
                            if (b.id == surf.current_buffer_id) {
                                for (c.pools[0..c.pool_count]) |p| {
                                    if (p.id == b.pool_id) {
                                        if (p.data) |ptr| {
                                            const pixels: [*]const u32 = @ptrCast(@alignCast(ptr + b.offset));
                                            const copy_w = @min(bounds.width(), b.width);
                                            const copy_h = @min(bounds.height(), b.height);

                                            var y: u32 = 0;
                                            while (y < copy_h) : (y += 1) {
                                                const src_row = y * (b.stride / 4);
                                                const dst_row = (bounds.y0 + @as(i32, @intCast(y))) * @as(i32, @intCast(surface.stride / 4)) + bounds.x0;
                                                if (dst_row >= 0) {
                                                    const d_idx: usize = @intCast(dst_row);
                                                    if (d_idx + copy_w <= surface.pixels.len) {
                                                        @memcpy(surface.pixels[d_idx .. d_idx + copy_w], pixels[src_row .. src_row + copy_w]);
                                                    }
                                                }
                                            }
                                        }
                                        break;
                                    }
                                }
                                break;
                            }
                        }
                    }
                }
            }

            surface.resetClip();
        },
        .mouse => {
            // Forward mouse events to Wayland pointer
            if (global_wayland_server) |*ws| {
                for (&ws.clients) |*slot| {
                    if (slot.*) |*c| {
                        for (c.objects[0..c.object_count]) |obj| {
                            if (obj.obj_type == .pointer) {
                                var m_payload: [16]u8 = undefined;
                                std.mem.writeInt(u32, m_payload[0..4], c.next_serial, .little);
                                c.next_serial += 1;
                                // 24.8 fixed point coordinates
                                const fx = @as(i32, @intCast(ev.data.mouse.point.x)) << 8;
                                const fy = @as(i32, @intCast(ev.data.mouse.point.y)) << 8;
                                std.mem.writeInt(i32, m_payload[4..8], fx, .little);
                                std.mem.writeInt(i32, m_payload[8..12], fy, .little);
                                c.sendEvent(obj.id, 2, m_payload[0..12]); // wl_pointer.motion
                                c.sendEvent(obj.id, 5, &[_]u8{}); // wl_pointer.frame
                            }
                        }
                    }
                }
            }
        },
        .key => {
            // Forward keys to Wayland keyboard
            if (global_wayland_server) |*ws| {
                for (&ws.clients) |*slot| {
                    if (slot.*) |*c| {
                        for (c.objects[0..c.object_count]) |obj| {
                            if (obj.obj_type == .keyboard) {
                                var k_payload: [16]u8 = undefined;
                                std.mem.writeInt(u32, k_payload[0..4], c.next_serial, .little);
                                c.next_serial += 1;
                                std.mem.writeInt(u32, k_payload[4..8], 0, .little); // time
                                std.mem.writeInt(u32, k_payload[8..12], ev.data.key.code, .little); // keycode
                                std.mem.writeInt(u32, k_payload[12..16], if (ev.data.key.value != 0) 1 else 0, .little); // state
                                c.sendEvent(obj.id, 3, &k_payload); // wl_keyboard.key
                            }
                        }
                    }
                }
            }
        },
        .close => {
            // User clicked close on window -> send xdg_toplevel.close event to app
            if (global_wayland_server) |*ws| {
                for (&ws.clients) |*slot| {
                    if (slot.*) |*c| {
                        if (surf.xdg_toplevel_id != 0) {
                            c.sendEvent(surf.xdg_toplevel_id, 1, &[_]u8{}); // xdg_toplevel.close
                        }
                    }
                }
            }
            surf.window_ptr = null;
        },
        else => {},
    }
    _ = win;
}

test "wayland: object tracking and event framing" {
    const testing = std.testing;

    var client = WaylandClient.init(testing.allocator, -1);
    defer client.deinit();

    // Verify wl_display at id 1
    const disp = client.findObject(1);
    try testing.expect(disp != null);
    try testing.expectEqual(ObjectType.display, disp.?.obj_type);

    // Add compositor and surface objects
    client.addObject(2, .compositor, 0);
    client.addObject(3, .surface, 0);

    const comp = client.findObject(2);
    try testing.expect(comp != null);
    try testing.expectEqual(ObjectType.compositor, comp.?.obj_type);

    // Test wire event framing
    client.sendEvent(1, 0, &[_]u8{ 42, 0, 0, 0 });
    try testing.expect(client.out_len == 12);
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, client.out_buf[0..4], .little));
    try testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, client.out_buf[4..6], .little));
    try testing.expectEqual(@as(u16, 12), std.mem.readInt(u16, client.out_buf[6..8], .little));
    try testing.expectEqual(@as(u32, 42), std.mem.readInt(u32, client.out_buf[8..12], .little));
}
