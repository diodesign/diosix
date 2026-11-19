// Child VM Kernel Command-Line & DNS Autoconfiguration Formatting.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub const SHIM_DEFAULT_MODULES =
    "loop,squashfs,sd-mod,isofs,virtio_mmio,virtio_blk,virtio_net";

pub const BootargsOptions = struct {
    vcpus: usize = 1,
    is_shim_boot: bool = false,
    custom_cmdline: ?[]const u8 = null,
    ip_autoconfig: ?[]const u8 = null,
};

/// Extracts up to two `:dns` suffixes (preferring local-subnet forwarders
/// before public resolvers) from `/etc/resolv.conf` content.
pub fn formatDnsSuffixFromResolv(
    allocator: std.mem.Allocator,
    resolv_content: []const u8,
) ![]u8 {
    var primary: ?[]const u8 = null;
    var secondary: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, resolv_content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "nameserver")) continue;
        const ip = std.mem.trim(u8, line["nameserver".len..], " \t");
        if (ip.len == 0 or std.mem.startsWith(u8, ip, "127.") or
            std.mem.indexOfScalar(u8, ip, ':') != null)
        {
            continue;
        }
        const is_local = std.mem.startsWith(u8, ip, "10.") or
            std.mem.startsWith(u8, ip, "192.168.") or
            std.mem.startsWith(u8, ip, "172.");
        if (is_local and (primary == null or
            !std.mem.startsWith(u8, primary.?, "10.")))
        {
            if (primary) |prev| {
                if (!std.mem.eql(u8, prev, ip)) {
                    secondary = prev;
                }
            }
            primary = ip;
        } else if (primary == null) {
            primary = ip;
        } else if (secondary == null and !std.mem.eql(u8, primary.?, ip)) {
            secondary = ip;
        }
    }
    if (primary) |p| {
        if (secondary) |s| {
            return std.fmt.allocPrint(allocator, ":{s}:{s}", .{ p, s });
        }
        return std.fmt.allocPrint(allocator, ":{s}", .{p});
    }
    return allocator.dupe(u8, "");
}

/// Builds the effective kernel command line for a child guest VM, merging
/// default console/SMP parameters with any user-supplied `--cmdline`.
pub fn formatEffectiveBootargs(
    allocator: std.mem.Allocator,
    vcpus: usize,
    custom_cmdline: ?[]const u8,
) ![]u8 {
    return formatBootargs(allocator, .{
        .vcpus = vcpus,
        .custom_cmdline = custom_cmdline,
    });
}

pub fn formatBootargs(
    allocator: std.mem.Allocator,
    opts: BootargsOptions,
) ![]u8 {
    const base_vcpus: usize = @max(@as(usize, 1), opts.vcpus);
    const default_console = if (opts.is_shim_boot)
        "console=tty0 console=ttyS0,115200 earlycon=sbi"
    else
        "console=tty0 console=hvc0 earlycon=sbi";

    if (opts.custom_cmdline) |custom| {
        const trimmed = std.mem.trim(u8, custom, " \t\r\n");
        if (trimmed.len > 0) {
            if (std.mem.indexOf(u8, trimmed, "console=") != null) {
                return allocator.dupe(u8, trimmed);
            }
            return std.fmt.allocPrint(
                allocator,
                "{s} maxcpus={d} {s}",
                .{ default_console, base_vcpus, trimmed },
            );
        }
    }

    if (opts.is_shim_boot) {
        if (opts.ip_autoconfig) |ip_arg| {
            if (ip_arg.len > 0) {
                return std.fmt.allocPrint(
                    allocator,
                    "{s} maxcpus={d} modules={s} ip={s}",
                    .{
                        default_console,
                        base_vcpus,
                        SHIM_DEFAULT_MODULES,
                        ip_arg,
                    },
                );
            }
        }
        return std.fmt.allocPrint(
            allocator,
            "{s} maxcpus={d} modules={s}",
            .{ default_console, base_vcpus, SHIM_DEFAULT_MODULES },
        );
    }

    return std.fmt.allocPrint(
        allocator,
        "{s} rootfstype=ramfs cma=0M no4lvl maxcpus={d} lpj=50000 " ++
            "rcupdate.rcu_cpu_stall_suppress=1 unaligned_scalar_speed=fast",
        .{ default_console, base_vcpus },
    );
}

test "vm/bootargs: DNS suffix extraction and shim vs ELF bootargs" {
    std.testing.refAllDecls(@This());
    const testing = std.testing;
    const alloc = testing.allocator;

    const merged = try formatEffectiveBootargs(alloc, 2, "root=/dev/vda rw");
    defer alloc.free(merged);
    try testing.expect(std.mem.indexOf(u8, merged, "root=/dev/vda rw") != null);
    try testing.expect(std.mem.indexOf(u8, merged, "console=hvc0") != null);

    const dns = try formatDnsSuffixFromResolv(
        alloc,
        "nameserver 1.1.1.1\nnameserver 8.8.8.8\nnameserver 10.0.2.3\n",
    );
    defer alloc.free(dns);
    try testing.expectEqualStrings(":10.0.2.3:1.1.1.1", dns);

    const shim_args = try formatBootargs(alloc, .{
        .vcpus = 2,
        .is_shim_boot = true,
        .ip_autoconfig = "10.0.3.2::10.0.3.1:255.255.255.0:" ++
            "web:eth0:off:1.1.1.1",
    });
    defer alloc.free(shim_args);
    try testing.expect(
        std.mem.indexOf(u8, shim_args, "console=ttyS0,115200") != null,
    );
    try testing.expect(
        std.mem.indexOf(u8, shim_args, "ip=10.0.3.2::10.0.3.1") != null,
    );
}
