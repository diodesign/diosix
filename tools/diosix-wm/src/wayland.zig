const std = @import("std");
const posix = std.posix;
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
        @memcpy(z_path[0..socket_path.len], socket_path);
        z_path[socket_path.len] = 0;

        _ = posix.unlink(z_path[0..socket_path.len :0]) catch {};

        var addr = posix.sockaddr.un{
            .family = posix.AF.UNIX,
            .path = undefined,
        };
        @memset(&addr.path, 0);
        @memcpy(addr.path[0..socket_path.len], socket_path);

        const fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0) catch -1;
        if (fd >= 0) {
            _ = posix.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch {};
            _ = posix.listen(fd, 16) catch {};
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
            posix.close(self.listen_fd);
        }
    }

    pub fn addWindow(self: *WaylandCompositorServer, win: dec.WindowState) !void {
        try self.windows.append(self.allocator, win);
    }
};
