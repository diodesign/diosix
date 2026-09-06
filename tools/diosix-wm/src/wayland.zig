const std = @import("std");
const linux = std.os.linux;
const fb = @import("framebuffer.zig");
const dec = @import("decorator.zig");

pub const WlBuffer = struct {
    width: u32,
    height: u32,
    stride: u32,
    format: u32,
    data: []u32,
};

pub const ClientConnection = struct {
    cid: usize,
    domain_name: []const u8,
    trust: dec.DomainTrust,
    fd: i32,

    pub fn init(cid: usize, domain_name: []const u8, trust: dec.DomainTrust, fd: i32) ClientConnection {
        return ClientConnection{
            .cid = cid,
            .domain_name = domain_name,
            .trust = trust,
            .fd = fd,
        };
    }
};

pub const WaylandCompositorServer = struct {
    allocator: std.mem.Allocator,
    windows: std.ArrayList(dec.WindowState),
    listen_fd: i32,

    pub fn init(allocator: std.mem.Allocator, socket_path: []const u8) !WaylandCompositorServer {
        var z_path: [256]u8 = undefined;
        if (socket_path.len >= z_path.len) return error.NameTooLong;
        @memcpy(z_path[0..socket_path.len], socket_path);
        z_path[socket_path.len] = 0;

        _ = linux.unlink(@ptrCast(&z_path));

        var addr = linux.sockaddr.un{
            .family = linux.AF.UNIX,
            .path = undefined,
        };
        @memset(&addr.path, 0);
        const copy_len = @min(socket_path.len, addr.path.len - 1);
        @memcpy(addr.path[0..copy_len], socket_path[0..copy_len]);

        const fd_res = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.NONBLOCK, 0);
        const fd_signed: isize = @bitCast(fd_res);
        var fd: i32 = -1;
        if (fd_signed >= 0) {
            fd = @intCast(fd_signed);
            _ = linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.un));
            _ = linux.listen(fd, 16);
        }

        return WaylandCompositorServer{
            .allocator = allocator,
            .windows = std.ArrayList(dec.WindowState).empty,
            .listen_fd = fd,
        };
    }

    pub fn deinit(self: *WaylandCompositorServer) void {
        self.windows.deinit(self.allocator);
        if (self.listen_fd >= 0) {
            _ = linux.close(self.listen_fd);
        }
    }

    pub fn addWindow(self: *WaylandCompositorServer, win: dec.WindowState) !void {
        try self.windows.append(self.allocator, win);
    }
};
