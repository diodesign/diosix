// Shared CLI Utilities, File I/O, Subprocess Execution, and Guest Registry.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const api = @import("api.zig");
const registry = @import("registry.zig");
const sysconfig = @import("sysconfig.zig");
const output = @import("common/output.zig");

pub const GUEST_REGISTRY_PATH = registry.GUEST_REGISTRY_PATH;
pub const GuestRegistryKey = registry.GuestRegistryKey;
pub const GuestRegistryEntry = registry.GuestRegistryEntry;
pub const GuestRegistryIter = registry.GuestRegistryIter;
pub const matchTarget = registry.matchTarget;
pub const findAttachedGuest = registry.findAttachedGuest;
pub const removeGuestFromRegistry = registry.removeGuestFromRegistry;
pub const saveGuestRegistry = registry.saveGuestRegistry;
pub const printGuestLine = registry.printGuestLine;

pub const printStr = output.printStr;
pub const printFmt = output.printFmt;
pub const JsonFlag = output.JsonFlag;
pub const isJsonFlag = output.isJsonFlag;
pub const setExeName = output.setExeName;
pub const getExeName = output.getExeName;
pub const printApiError = output.printApiError;
pub const sanitizeJsonStr = output.sanitizeJsonStr;
pub const writeJsonEscaped = output.writeJsonEscaped;
pub const escapeJsonAlloc = output.escapeJsonAlloc;
pub const trimAscii = output.trimAscii;
pub const trimWhitespace = output.trimWhitespace;
pub const unquoteToml = output.unquoteToml;
pub const copyStr = output.copyStr;
pub const setFixedBuf = output.setFixedBuf;
pub const bytesToHex = output.bytesToHex;
pub const sha256Hex = output.sha256Hex;
pub const toPathZ = output.toPathZ;

pub const CID_PARENT: usize = api.CID_PARENT;
pub const CID_SELF: usize = api.CID_SELF;
pub const CID_FIRST_CHILD: usize = api.CID_FIRST_CHILD;

pub const MAX_POSITIONAL_ARGS: usize = 8;
pub const MAX_IPC_BUF_LEN: usize = 4096;
pub const MAX_PATH_LEN: usize = 4096;
pub const MAX_ELF_FILE_SIZE: usize = 256 * 1024 * 1024;
pub const MAX_DTB_FILE_SIZE: usize = 2 * 1024 * 1024;
pub const MAX_MANIFEST_SIZE: usize = 1024 * 1024;

pub const PAGE_SIZE_KB: usize = 4;
pub const KB_PER_MB: usize = 1024;
pub const DEV_MEM_PAGE_SIZE: usize = 4096;
pub const DEFAULT_FILE_MODE: usize = 0o644;
pub const PRIVATE_FILE_MODE: usize = 0o600;
pub const CATALOG_CONFIG_PATH = sysconfig.DEFAULT_CATALOG_CONFIG_PATH;

const CMDLINE_READ_MAX: usize = 4096;
const SYSCONFIG_READ_MAX: usize = 65536;

pub const WAIT_SIGNAL_MASK: i32 = 0x7f;
pub const WAIT_EXIT_SHIFT: u5 = 8;
pub const WAIT_EXIT_MASK: i32 = 0xff;
pub const WAIT_SIGNAL_EXIT_BASE: u32 = 128;
pub const SUBPROCESS_EXEC_ERR: u8 = 127;
pub const SUBPROCESS_WAIT_ERR: u32 = 255;

pub const TargetAlias = enum {
    self,
    parent,
    root,
    current,
    @"0",
};

pub const LinuxDirent64 = extern struct {
    d_ino: u64,
    d_off: i64,
    d_reclen: u16,
    d_type: u8,
    d_name: [0]u8,
};

pub fn parseCid(str: []const u8) !usize {
    if (std.meta.stringToEnum(TargetAlias, str)) |alias| {
        return switch (alias) {
            .self, .current => CID_SELF,
            .parent, .root, .@"0" => CID_PARENT,
        };
    }
    return std.fmt.parseInt(usize, str, 10);
}

pub fn isArch(str: []const u8) bool {
    return std.meta.stringToEnum(api.TargetArch, str) != null;
}

pub fn isSafeIdentifier(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) {
        return false;
    }
    if (std.mem.indexOf(u8, name, "..") != null) return false;
    for (name) |c| {
        if (c == '/' or c == '\\' or c <= 0x20 or c >= 0x7f) return false;
    }
    return true;
}

fn matchesPathPrefix(path: []const u8, prefix: []const u8) bool {
    if (prefix.len == 0 or !std.mem.startsWith(u8, path, prefix)) return false;
    if (prefix[prefix.len - 1] == '/') return path.len > prefix.len;
    return path.len > prefix.len and path[prefix.len] == '/';
}

pub fn isSafeStoragePath(path: []const u8, allowed_prefix: []const u8) bool {
    if (path.len == 0 or path.len >= MAX_PATH_LEN) return false;
    if (std.mem.indexOf(u8, path, "..") != null) return false;
    if (std.mem.startsWith(u8, path, "/")) {
        return matchesPathPrefix(path, allowed_prefix) or
            matchesPathPrefix(path, sysconfig.TMP_DIR_PREFIX);
    }
    return isSafeIdentifier(path);
}

pub fn parseMemorySizeMb(str: []const u8) usize {
    if (str.len == 0) return 256;
    var num_len: usize = 0;
    while (num_len < str.len and std.ascii.isDigit(str[num_len])) {
        num_len += 1;
    }
    if (num_len == 0) return 256;
    const base_val = std.fmt.parseInt(usize, str[0..num_len], 10) catch 256;
    const unit = str[num_len..];

    if (std.mem.startsWith(u8, unit, "G") or
        std.mem.startsWith(u8, unit, "g"))
    {
        return std.math.mul(usize, base_val, 1024) catch 256;
    } else if (std.mem.startsWith(u8, unit, "K") or
        std.mem.startsWith(u8, unit, "k"))
    {
        return @max(1, base_val / 1024);
    }
    return base_val;
}

pub fn readBinaryFile(path: []const u8, max_size: usize) ![]u8 {
    if (max_size == 0) return @constCast(&[_]u8{});
    var path_buf: [MAX_PATH_LEN]u8 = undefined;
    if (path.len >= path_buf.len) return error.PathTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    const zpath: [*:0]const u8 = @ptrCast(path_buf[0..path.len :0]);
    const fd_res = linux.open(zpath, .{ .ACCMODE = .RDONLY }, 0);
    const fd_signed: isize = @bitCast(fd_res);
    if (fd_signed < 0) return error.FileNotFound;
    const fd: i32 = @intCast(fd_signed);
    defer _ = linux.close(fd);

    const end_offset = linux.lseek(fd, 0, linux.SEEK.END);
    _ = linux.lseek(fd, 0, linux.SEEK.SET);
    const end_signed: isize = @bitCast(end_offset);
    var file_size: usize = max_size;
    if (end_signed > 0) {
        file_size = @min(@as(usize, @intCast(end_signed)), max_size);
    }
    const alloc_size = std.mem.alignForward(
        usize,
        file_size,
        DEV_MEM_PAGE_SIZE,
    );

    const anon_res = linux.mmap(
        null,
        alloc_size,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    const anon_signed: isize = @bitCast(anon_res);
    if (anon_signed < 0) return error.OutOfMemory;
    const buf: [*]u8 = @ptrFromInt(anon_res);
    var total_read: usize = 0;
    while (total_read < file_size) {
        const rem = file_size - total_read;
        const read_res = linux.read(fd, buf + total_read, rem);
        const r_signed: isize = @bitCast(read_res);
        if (r_signed <= 0) break;
        total_read += @intCast(r_signed);
    }
    if (total_read == 0) {
        _ = linux.munmap(buf, alloc_size);
        return @constCast(&[_]u8{});
    }
    const used_alloc = std.mem.alignForward(
        usize,
        total_read,
        DEV_MEM_PAGE_SIZE,
    );
    if (used_alloc < alloc_size) {
        _ = linux.munmap(buf + used_alloc, alloc_size - used_alloc);
    }
    return buf[0..total_read];
}

pub fn unmapBinaryFile(slice: []const u8) void {
    if (slice.len > 0) {
        const alloc_size = std.mem.alignForward(
            usize,
            slice.len,
            DEV_MEM_PAGE_SIZE,
        );
        _ = linux.munmap(@constCast(slice.ptr), alloc_size);
    }
}

pub fn writeFile(path: []const u8, content: []const u8) !void {
    var path_buf: [MAX_PATH_LEN]u8 = undefined;
    if (path.len >= path_buf.len) return error.PathTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    const flags: linux.O = .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
    };
    const zpath: [*:0]const u8 = @ptrCast(path_buf[0..path.len :0]);
    const fd_res = linux.open(zpath, flags, DEFAULT_FILE_MODE);
    const fd_signed: isize = @bitCast(fd_res);
    if (fd_signed < 0) return error.CannotOpenFile;
    const fd: i32 = @intCast(fd_signed);
    defer _ = linux.close(fd);

    var written: usize = 0;
    while (written < content.len) {
        const rem = content.len - written;
        const rc = linux.write(fd, content.ptr + written, rem);
        const signed_rc: isize = @bitCast(rc);
        if (signed_rc <= 0) return error.WriteFailed;
        written += @intCast(signed_rc);
    }
}

pub fn fileExistsPath(path: [*:0]const u8) bool {
    const fd_res = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    const fd_signed: isize = @bitCast(fd_res);
    if (fd_signed >= 0) {
        _ = linux.close(@intCast(fd_signed));
        return true;
    }
    return false;
}

pub fn appendFileLine(path: [*:0]const u8, line: []const u8) !void {
    const flags: linux.O = .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .APPEND = true,
    };
    const fd_res = linux.open(path, flags, PRIVATE_FILE_MODE);
    const fd_signed: isize = @bitCast(fd_res);
    if (fd_signed < 0) return error.CannotOpenFile;
    const fd: i32 = @intCast(fd_signed);
    defer _ = linux.close(fd);

    var written: usize = 0;
    while (written < line.len) {
        const rc = linux.write(fd, line.ptr + written, line.len - written);
        const signed_rc: isize = @bitCast(rc);
        if (signed_rc <= 0) return error.WriteFailed;
        written += @intCast(signed_rc);
    }
    if (line.len == 0 or line[line.len - 1] != '\n') {
        const nl_rc = linux.write(fd, "\n", 1);
        const nl_signed: isize = @bitCast(nl_rc);
        if (nl_signed <= 0) return error.WriteFailed;
    }
}

pub fn runSubprocess(argv: [*:null]const ?[*:0]const u8) u32 {
    const pid_res = linux.fork();
    const pid_signed: isize = @bitCast(pid_res);
    if (pid_signed < 0) return SUBPROCESS_WAIT_ERR;
    if (pid_signed == 0) {
        const devnull_res = linux.open(
            sysconfig.DEV_NULL_PATH,
            .{ .ACCMODE = .RDWR },
            0,
        );
        const devnull_signed: isize = @bitCast(devnull_res);
        if (devnull_signed >= 0) {
            _ = linux.dup2(@intCast(devnull_signed), linux.STDOUT_FILENO);
            _ = linux.dup2(@intCast(devnull_signed), linux.STDERR_FILENO);
            _ = linux.close(@intCast(devnull_signed));
        }
        const envp: [*:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{
            "PATH=/bin:/sbin:/usr/bin:/usr/sbin",
            null,
        };
        _ = linux.execve(argv[0].?, argv, envp);
        linux.exit(SUBPROCESS_EXEC_ERR);
    }
    const pid: i32 = @intCast(pid_signed);
    var status: i32 = 0;
    while (true) {
        const wait_res = linux.waitpid(pid, &status, 0);
        const wait_signed: isize = @bitCast(wait_res);
        if (wait_signed >= 0) break;
        if (wait_signed == -@as(isize, @backingInt(linux.E.INTR))) continue;
        return SUBPROCESS_WAIT_ERR;
    }
    if ((status & WAIT_SIGNAL_MASK) == 0) {
        return @intCast((status >> WAIT_EXIT_SHIFT) & WAIT_EXIT_MASK);
    }
    return WAIT_SIGNAL_EXIT_BASE +
        @as(u32, @intCast(status & WAIT_SIGNAL_MASK));
}

pub fn detectSeatProfile() []const u8 {
    if (fileExistsPath(sysconfig.DEV_DRI_CARD0_PATH)) {
        if (fileExistsPath(sysconfig.DEV_TOUCHSCREEN0_PATH) or
            fileExistsPath(sysconfig.TOUCH_SEAT_PATH))
        {
            return "touch-tablet";
        }
        return "desktop-kbd";
    }
    return "headless-serial";
}

pub fn detectBootMode() []const u8 {
    if (readBinaryFile(
        sysconfig.PROC_CMDLINE_PATH,
        CMDLINE_READ_MAX,
    )) |cmdline| {
        defer unmapBinaryFile(cmdline);
        if (std.mem.indexOf(u8, cmdline, "diosix.mode=dev") != null) {
            return "dev";
        }
        if (std.mem.indexOf(u8, cmdline, "diosix.mode=live") != null) {
            return "live";
        }
    } else |_| {}
    return "installed";
}

pub fn generateEntropyBytes(out: []u8) !void {
    const gr_rc = linux.getrandom(out.ptr, out.len, 0);
    const gr_signed: isize = @bitCast(gr_rc);
    if (gr_signed == @as(isize, @intCast(out.len))) return;

    const fd_res = linux.open(
        sysconfig.DEV_URANDOM_PATH,
        .{ .ACCMODE = .RDONLY },
        0,
    );
    const fd_signed: isize = @bitCast(fd_res);
    if (fd_signed >= 0) {
        const fd: i32 = @intCast(fd_signed);
        defer _ = linux.close(fd);
        var read_total: usize = 0;
        while (read_total < out.len) {
            const rem = out.len - read_total;
            const rc = linux.read(fd, out.ptr + read_total, rem);
            const r_signed: isize = @bitCast(rc);
            if (r_signed <= 0) break;
            read_total += @intCast(r_signed);
        }
        if (read_total == out.len) return;
    }
    return error.EntropyUnavailable;
}

pub fn loadRuntimeSystemConfig() sysconfig.SystemConfig {
    if (readBinaryFile(
        sysconfig.DEFAULT_SYSCONFIG_PATH,
        SYSCONFIG_READ_MAX,
    )) |bytes| {
        defer unmapBinaryFile(bytes);
        return sysconfig.parseSystemConfigToml(bytes);
    } else |_| {}
    return sysconfig.SystemConfig.initDefaults();
}

test "common: parseCid, parseMemorySizeMb, and isSafeStoragePath" {
    std.testing.refAllDecls(@This());
    _ = registry;
    _ = output;

    try std.testing.expectEqual(CID_SELF, try parseCid("self"));
    try std.testing.expectEqual(CID_PARENT, try parseCid("parent"));
    try std.testing.expectEqual(@as(usize, 5), try parseCid("5"));

    try std.testing.expectEqual(@as(usize, 4096), parseMemorySizeMb("4G"));
    try std.testing.expectEqual(@as(usize, 512), parseMemorySizeMb("512M"));
    try std.testing.expectEqual(@as(usize, 2), parseMemorySizeMb("2048K"));
    try std.testing.expectEqual(@as(usize, 256), parseMemorySizeMb(""));

    const dir = "/var/lib/diosix/disks";
    try std.testing.expect(
        isSafeStoragePath("/var/lib/diosix/disks/a.img", dir),
    );
    try std.testing.expect(
        !isSafeStoragePath("/var/lib/diosix/disks-evil/a.img", dir),
    );
    try std.testing.expect(!isSafeStoragePath("/tmp-evil/a.img", dir));
}
