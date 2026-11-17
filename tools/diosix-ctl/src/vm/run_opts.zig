// Diosix Hypervisor Guest Management CLI — `dsx run` Option Parser.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const api = @import("../api.zig");
const common = @import("../common.zig");
const net = @import("../net.zig");
const manifest = @import("../manifest.zig");
const owned = @import("owned.zig");

pub const RunOption = enum {
    @"--name",
    @"-n",
    @"--domain",
    @"--manifest",
    @"-m",
    @"--vcpus",
    @"--ram",
    @"--pcpu",
    @"--pcpu-quota",
    @"--ram-quota",
    @"--disk",
    @"-d",
    @"--cdrom",
    @"--iso",
    @"--media",
    @"--initrd",
    @"--initramfs",
    @"--cmdline",
    @"--append",
    @"--bootargs",
    @"--ip",
    @"--trusted",
    @"--untrusted",
    @"--steward",
    @"--standby-root",
    @"--confidential",
    @"--dtb",
    @"--arch",
    @"-a",
    @"--net",
    @"--net-via",
    @"--packages",
    @"--user",
};

pub const ParsedRunOptions = struct {
    elf_path: ?[]const u8 = null,
    vm_name: ?[]const u8 = null,
    domain_name: ?[]const u8 = null,
    manifest_path: ?[]const u8 = null,
    vcpus: usize = 1,
    ram_str: []const u8 = "256 MB",
    pcpu_pct: usize = 0,
    ram_quota_str: ?[]const u8 = null,
    disk_str: ?[]const u8 = null,
    cdrom_str: ?[]const u8 = null,
    initrd_str: ?[]const u8 = null,
    cmdline_str: ?[]const u8 = null,
    ip_str: []const u8 = "",
    trusted: bool = false,
    is_steward: bool = false,
    is_standby_root: bool = false,
    is_confidential: bool = false,
    arch_str: []const u8 = "riscv64",
    dtb_path: ?[]const u8 = null,
    net_mode: ?net.NetMode = null,
    net_via_str: ?[]const u8 = null,
    packages_str: ?[]const u8 = null,
};

fn takeOpt(
    args: []const [*:0]const u8,
    idx: *usize,
    flag: []const u8,
) ?[]const u8 {
    if (idx.* + 1 >= args.len) {
        common.printFmt("Error: Option '{s}' requires a value.\n", .{flag});
        return null;
    }
    idx.* += 1;
    return std.mem.span(args[idx.*]);
}

pub fn parseRunArgs(
    args: []const [*:0]const u8,
    default_vcpus: usize,
    default_ram: []const u8,
    default_arch: []const u8,
    exe_name: []const u8,
) ?ParsedRunOptions {
    var opts = ParsedRunOptions{
        .vcpus = default_vcpus,
        .ram_str = default_ram,
        .arch_str = default_arch,
    };

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const span = std.mem.span(args[i]);
        if (std.meta.stringToEnum(RunOption, span)) |opt| {
            switch (opt) {
                .@"--name", .@"-n" => {
                    opts.vm_name = takeOpt(args, &i, "--name") orelse
                        return null;
                },
                .@"--domain" => {
                    opts.domain_name = takeOpt(args, &i, "--domain") orelse
                        return null;
                },
                .@"--manifest", .@"-m" => {
                    opts.manifest_path = takeOpt(args, &i, "--manifest") orelse
                        return null;
                },
                .@"--vcpus" => {
                    const v_str = takeOpt(args, &i, "--vcpus") orelse
                        return null;
                    opts.vcpus = std.fmt.parseInt(usize, v_str, 10) catch {
                        common.printStr("Error: Invalid '--vcpus' value.\n");
                        return null;
                    };
                    if (opts.vcpus == 0 or opts.vcpus > api.MAX_GUEST_VCPUS) {
                        common.printStr(
                            "Error: '--vcpus' must be between 1 and 4096.\n",
                        );
                        return null;
                    }
                },
                .@"--ram" => {
                    opts.ram_str = takeOpt(args, &i, "--ram") orelse
                        return null;
                },
                .@"--pcpu", .@"--pcpu-quota" => {
                    const p_str = takeOpt(args, &i, "--pcpu") orelse
                        return null;
                    const trimmed = std.mem.trimEnd(u8, p_str, "%");
                    opts.pcpu_pct = std.fmt.parseInt(usize, trimmed, 10) catch {
                        common.printStr("Error: Invalid '--pcpu' value.\n");
                        return null;
                    };
                    if (opts.pcpu_pct == 0 or
                        opts.pcpu_pct > api.MAX_CHILD_PCPU_QUOTA_PCT)
                    {
                        common.printStr(
                            "Error: '--pcpu' must be between 1 and 90%.\n",
                        );
                        return null;
                    }
                },
                .@"--ram-quota" => {
                    opts.ram_quota_str = takeOpt(args, &i, "--ram-quota") orelse
                        return null;
                },
                .@"--disk", .@"-d" => {
                    opts.disk_str = takeOpt(args, &i, "--disk") orelse
                        return null;
                },
                .@"--cdrom", .@"--iso", .@"--media" => {
                    opts.cdrom_str = takeOpt(args, &i, "--cdrom") orelse
                        return null;
                },
                .@"--initrd", .@"--initramfs" => {
                    opts.initrd_str = takeOpt(args, &i, "--initrd") orelse
                        return null;
                },
                .@"--cmdline", .@"--append", .@"--bootargs" => {
                    opts.cmdline_str = takeOpt(args, &i, "--cmdline") orelse
                        return null;
                },
                .@"--ip" => {
                    opts.ip_str = takeOpt(args, &i, "--ip") orelse return null;
                },
                .@"--trusted" => opts.trusted = true,
                .@"--untrusted" => opts.trusted = false,
                .@"--steward" => opts.is_steward = true,
                .@"--standby-root" => opts.is_standby_root = true,
                .@"--confidential" => opts.is_confidential = true,
                .@"--dtb" => {
                    opts.dtb_path = takeOpt(args, &i, "--dtb") orelse
                        return null;
                },
                .@"--arch", .@"-a" => {
                    opts.arch_str = takeOpt(args, &i, "--arch") orelse
                        return null;
                },
                .@"--net" => {
                    const m_str = takeOpt(args, &i, "--net") orelse return null;
                    opts.net_mode = net.parseNetMode(m_str) orelse {
                        common.printFmt(
                            "Error: Invalid '--net' mode '{s}'.\n",
                            .{m_str},
                        );
                        return null;
                    };
                },
                .@"--net-via" => {
                    opts.net_via_str = takeOpt(args, &i, "--net-via") orelse
                        return null;
                },
                .@"--packages" => {
                    opts.packages_str = takeOpt(args, &i, "--packages") orelse
                        return null;
                },
                .@"--user" => {
                    common.printStr(
                        "Error: Unrecognized option '--user'. " ++
                            "To specify a VM name, use '--name <name>'.\n",
                    );
                    return null;
                },
            }
        } else if (common.isArch(span)) {
            opts.arch_str = span;
        } else if (std.mem.startsWith(u8, span, "-")) {
            common.printFmt(
                "Error: Unknown option '{s}'. Use '{s} run' for usage.\n",
                .{ span, exe_name },
            );
            return null;
        } else if (opts.elf_path == null) {
            opts.elf_path = span;
        }
    }
    return opts;
}

pub fn copyDomainBootExtras(
    strings: *owned.OwnedStrings,
    dom: manifest.DomainSpec,
    initrd_str: *?[]const u8,
    cmdline_str: *?[]const u8,
) !void {
    if (initrd_str.* == null and dom.initrd.len > 0) {
        initrd_str.* = try strings.dupe(dom.initrd);
    }
    if (cmdline_str.* == null and dom.cmdline.len > 0) {
        cmdline_str.* = try strings.dupe(dom.cmdline);
    }
}

test "vm/run_opts: RunOption enum parses --initrd and --cmdline" {
    std.testing.refAllDecls(@This());
    try std.testing.expectEqual(
        RunOption.@"--initrd",
        std.meta.stringToEnum(RunOption, "--initrd").?,
    );
    try std.testing.expectEqual(
        RunOption.@"--cmdline",
        std.meta.stringToEnum(RunOption, "--cmdline").?,
    );
}
