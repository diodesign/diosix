// Diosix Guest Registry Persistence (/var/run/diosix/guests.toml).
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const common = @import("common.zig");
const manifest = @import("manifest.zig");

pub const GuestRegistryKey = enum {
    cid,
    name,
    vcpus,
    ram,
    disk,
    cdrom,
    ip,
    trust,
    status,
};

pub const GuestRegistryEntry = struct {
    cid: usize = 0,
    name: []const u8 = "",
    vcpus: usize = 1,
    ram: []const u8 = "256 MB",
    disk: []const u8 = "",
    cdrom: []const u8 = "",
    ip: []const u8 = "",
    trust: []const u8 = "untrusted",
    status: []const u8 = "running",
};

pub const GuestRegistryIter = struct {
    lexer: manifest.ManifestLexer,
    done: bool = false,

    pub fn init(content: []const u8) GuestRegistryIter {
        return .{ .lexer = manifest.ManifestLexer.init(content) };
    }

    pub fn next(self: *GuestRegistryIter) ?GuestRegistryEntry {
        if (self.done) return null;
        var entry = GuestRegistryEntry{};
        while (true) {
            const tok = self.lexer.next();
            if (tok.tag == .eof) {
                self.done = true;
                if (entry.cid > 0 or entry.name.len > 0) return entry;
                return null;
            }
            if (tok.tag == .bracket_open) {
                if (entry.cid > 0 or entry.name.len > 0) return entry;
                entry = GuestRegistryEntry{};
                continue;
            }
            if (tok.tag == .ident or tok.tag == .string) {
                const key = tok.val;
                if (self.lexer.next().tag != .equals) continue;
                const val = self.lexer.next().val;
                if (std.meta.stringToEnum(GuestRegistryKey, key)) |gk| {
                    switch (gk) {
                        .cid => {
                            entry.cid =
                                std.fmt.parseInt(usize, val, 10) catch 0;
                        },
                        .name => entry.name = val,
                        .vcpus => {
                            entry.vcpus =
                                std.fmt.parseInt(usize, val, 10) catch 1;
                        },
                        .ram => entry.ram = val,
                        .disk => entry.disk = val,
                        .cdrom => entry.cdrom = val,
                        .ip => entry.ip = val,
                        .trust => entry.trust = val,
                        .status => entry.status = val,
                    }
                }
            }
        }
    }
};

pub fn matchTarget(
    target_str: []const u8,
    target_cid: usize,
    entry_cid: usize,
    entry_name: []const u8,
) bool {
    if (target_cid > 0 and entry_cid == target_cid) return true;
    if (target_str.len == 0 or entry_name.len == 0) return false;
    if (std.mem.eql(u8, target_str, entry_name)) return true;
    if (target_cid == 0 and std.mem.startsWith(u8, entry_name, target_str)) {
        return true;
    }
    return false;
}

pub fn findAttachedGuest(disk_path: []const u8, out_buf: []u8) []const u8 {
    const content = common.readBinaryFile(
        "/var/run/diosix/guests.toml",
        common.MAX_MANIFEST_SIZE,
    ) catch return "-";
    defer common.unmapBinaryFile(content);

    var iter = GuestRegistryIter.init(content);
    while (iter.next()) |entry| {
        if (entry.disk.len == 0) continue;
        const matches = std.mem.eql(u8, entry.disk, disk_path) or
            std.mem.endsWith(u8, disk_path, entry.disk) or
            std.mem.endsWith(u8, entry.disk, disk_path);
        if (matches and std.mem.eql(u8, entry.status, "running")) {
            return std.fmt.bufPrint(
                out_buf,
                "{s} (CID {d})",
                .{ entry.name, entry.cid },
            ) catch entry.name;
        }
    }
    return "-";
}

const REGISTRY_ENTRY_FMT =
    \\[[guest]]
    \\cid = {d}
    \\name = "{s}"
    \\vcpus = {d}
    \\ram = "{s}"
    \\disk = "{s}"
    \\cdrom = "{s}"
    \\ip = "{s}"
    \\trust = "{s}"
    \\status = "{s}"
    \\
    \\
;

pub fn removeGuestFromRegistry(target_cid: usize) void {
    const content = common.readBinaryFile(
        "/var/run/diosix/guests.toml",
        common.MAX_MANIFEST_SIZE,
    ) catch return;
    defer common.unmapBinaryFile(content);

    const allocator = std.heap.page_allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var iter = GuestRegistryIter.init(content);
    while (iter.next()) |e| {
        if (e.cid >= common.CID_FIRST_CHILD and e.cid != target_cid) {
            var entry_buf: [512]u8 = undefined;
            const entry = std.fmt.bufPrint(
                &entry_buf,
                REGISTRY_ENTRY_FMT,
                .{
                    e.cid,
                    e.name,
                    e.vcpus,
                    e.ram,
                    e.disk,
                    e.cdrom,
                    e.ip,
                    e.trust,
                    e.status,
                },
            ) catch "";
            out.appendSlice(allocator, entry) catch {};
        }
    }

    _ = common.writeFile("/var/run/diosix/guests.toml", out.items) catch {};
}

pub fn saveGuestRegistry(
    cid: usize,
    name: []const u8,
    vcpus: usize,
    ram: []const u8,
    disk: []const u8,
    cdrom: []const u8,
    ip: []const u8,
    trust: []const u8,
    status: []const u8,
) void {
    removeGuestFromRegistry(cid);
    _ = linux.mkdir("/var/run/diosix", 0o755);

    var entry_buf: [512]u8 = undefined;
    const entry = std.fmt.bufPrint(&entry_buf, REGISTRY_ENTRY_FMT, .{
        cid, name, vcpus, ram, disk, cdrom, ip, trust, status,
    }) catch return;

    const flags: linux.O = .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .APPEND = true,
    };
    const fd_res = linux.open("/var/run/diosix/guests.toml", flags, 0o644);
    const fd_signed: isize = @bitCast(fd_res);
    if (fd_signed >= 0) {
        const fd: i32 = @intCast(fd_signed);
        defer _ = linux.close(fd);
        _ = linux.write(fd, entry.ptr, entry.len);
    }
}

pub fn printGuestLine(
    cid: usize,
    name: []const u8,
    vcpus: usize,
    ram: []const u8,
    status: []const u8,
    trust: []const u8,
    ip: []const u8,
) void {
    var line_buf: [256]u8 = undefined;
    const ep_str = if (std.mem.eql(u8, ip, "local") or cid == 1)
        "local"
    else if (ip.len > 0)
        ip
    else
        "dsx login";

    const display_name = if (name.len > 0) name else "guest";
    const line = std.fmt.bufPrint(
        &line_buf,
        "{d:<5} {s:<16} {d:<7} {s:<9} {s:<9} {s:<11} {s}\n",
        .{ cid, display_name, vcpus, ram, status, trust, ep_str },
    ) catch return;
    common.printStr(line);
}

test "registry: matchTarget and GuestRegistryIter" {
    std.testing.refAllDecls(@This());
    try std.testing.expect(matchTarget("2", 2, 2, "worker"));
    try std.testing.expect(!matchTarget("2", 2, 20, "20-worker"));
    try std.testing.expect(!matchTarget("", 0, 2, "worker"));
    try std.testing.expect(matchTarget("work", 0, 2, "worker"));

    const sample =
        \\[[guest]]
        \\cid = 2
        \\name = "alpha"
        \\ip = "10.0.3.2"
        \\[[guest]]
        \\cid = 3
        \\name = "beta"
        \\ip = "10.0.3.3"
    ;
    var iter = GuestRegistryIter.init(sample);
    const e1 = iter.next().?;
    try std.testing.expectEqual(@as(usize, 2), e1.cid);
    try std.testing.expectEqualStrings("alpha", e1.name);
    const e2 = iter.next().?;
    try std.testing.expectEqual(@as(usize, 3), e2.cid);
    try std.testing.expectEqualStrings("beta", e2.name);
    try std.testing.expect(iter.next() == null);
}
