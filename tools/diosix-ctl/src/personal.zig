// Diosix Personal Desktop Lifecycle & Profile CLI (`dsx personal`).
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const api = @import("api.zig");
const common = @import("common.zig");
const config = @import("personal/config.zig");
const launch = @import("personal/launch.zig");

const Subcommand = enum {
    status,
    start,
    stop,
    @"switch",
    configure,
    help,
    @"--help",
    @"-h",
};

fn cmdStatus(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    sub_args: []const [*:0]const u8,
) void {
    var json_mode = false;
    for (sub_args) |arg| {
        const s = std.mem.span(arg);
        if (std.mem.eql(u8, s, "--json") or std.mem.eql(u8, s, "-j")) {
            json_mode = true;
        }
    }
    var cfg = launch.loadEffectiveConfig(allocator) catch {
        common.printStr("Error: Could not load personal configuration.\n");
        return;
    };
    defer cfg.deinit();

    const active = launch.readActiveDesktop(client);
    const active_cid: usize = if (active) |a| a.cid else 0;
    const active_name: []const u8 = if (active) |*a| a.profile() else "";

    if (json_mode) {
        common.printFmt(
            "{{\"running\":{s},\"cid\":{d},\"active_profile\":\"{s}\"," ++
                "\"default_profile\":\"{s}\",\"auto_start\":{s}," ++
                "\"dma_trusted\":{s},\"profile_count\":{d}}}\n",
            .{
                if (active != null) "true" else "false",
                active_cid,
                active_name,
                cfg.default_profile,
                if (cfg.auto_start) "true" else "false",
                if (cfg.desktop.dma_trusted) "true" else "false",
                cfg.profile_count,
            },
        );
        return;
    }

    common.printFmt(
        "Diosix Personal Desktop Status\n" ++
            "  State           : {s}\n" ++
            "  Active profile  : {s} (CID {d})\n" ++
            "  Default profile : {s}\n" ++
            "  Auto-start      : {s}\n" ++
            "  DMA trusted     : {s}\n",
        .{
            if (active != null) "running" else "stopped",
            if (active_name.len > 0) active_name else "none",
            active_cid,
            cfg.default_profile,
            if (cfg.auto_start) "enabled" else "disabled",
            if (cfg.desktop.dma_trusted) "true" else "false",
        },
    );
}

fn cmdConfigure(
    allocator: std.mem.Allocator,
    sub_args: []const [*:0]const u8,
) !void {
    var cfg = try launch.loadEffectiveConfig(allocator);
    defer cfg.deinit();

    const CfgOpt = enum {
        @"--profile",
        @"--default",
        @"--auto-start",
        @"--image",
        @"--ram",
        @"--vcpus",
        @"--cpu-pct",
        @"--dma-trusted",
        @"--unbind",
        @"--mmio",
        @"--irq",
        @"--keep-fdt",
        @"--cmdline",
    };

    var target_name: []const u8 = "desktop";
    var i: usize = 0;
    while (i < sub_args.len) : (i += 1) {
        const key = std.mem.span(sub_args[i]);
        if (std.mem.eql(u8, key, "--profile") and i + 1 < sub_args.len) {
            target_name = std.mem.span(sub_args[i + 1]);
            break;
        }
    }
    const prof = try cfg.upsertProfile(target_name);

    i = 0;
    while (i < sub_args.len) : (i += 1) {
        const s = std.mem.span(sub_args[i]);
        const opt = std.meta.stringToEnum(CfgOpt, s) orelse {
            common.printFmt("Error: Unknown configure option '{s}'.\n", .{s});
            return;
        };
        if (i + 1 >= sub_args.len) {
            common.printFmt("Error: Option '{s}' requires a value.\n", .{s});
            return;
        }
        i += 1;
        const val = std.mem.span(sub_args[i]);
        switch (opt) {
            .@"--profile" => {},
            .@"--default" => cfg.default_profile = try cfg.strings.dupe(val),
            .@"--auto-start" => cfg.auto_start = std.mem.eql(u8, val, "true"),
            .@"--image" => prof.image = try cfg.strings.dupe(val),
            .@"--ram" => {
                prof.ram_mb = std.fmt.parseInt(usize, val, 10) catch
                    common.parseMemorySizeMb(val);
            },
            .@"--vcpus" => prof.vcpus = std.fmt.parseInt(usize, val, 10) catch
                prof.vcpus,
            .@"--cpu-pct" => {
                prof.cpu_pct = std.fmt.parseInt(usize, val, 10) catch
                    prof.cpu_pct;
            },
            .@"--dma-trusted" => {
                prof.dma_trusted = std.mem.eql(u8, val, "true");
            },
            .@"--unbind" => prof.unbind_platform = try cfg.strings.dupe(val),
            .@"--mmio" => {
                try config.setCsvList(
                    &cfg.strings,
                    &prof.mmio,
                    &prof.mmio_count,
                    val,
                );
            },
            .@"--irq" => {
                try config.setCsvList(
                    &cfg.strings,
                    &prof.irq,
                    &prof.irq_count,
                    val,
                );
            },
            .@"--keep-fdt" => {
                try config.setCsvList(
                    &cfg.strings,
                    &prof.keep_fdt,
                    &prof.keep_fdt_count,
                    val,
                );
            },
            .@"--cmdline" => prof.cmdline = try cfg.strings.dupe(val),
        }
    }

    try launch.saveEffectiveConfig(allocator, &cfg);
    common.printFmt(
        "✓ Updated personal desktop configuration (profile '{s}').\n",
        .{prof.name},
    );
}

fn printUsage() void {
    common.printStr(
        \\Usage: dsx personal <subcommand> [options]
        \\  status [--json]                     Show active desktop VM & profile
        \\  start [profile] [run overrides]     Start configured desktop VM
        \\  stop                                Terminate running desktop VM
        \\  switch <profile> [run overrides]    Stop active desktop & start next
        \\  configure [--profile <name>] [...]  Update /etc/diosix/personal.toml
        \\
    );
}

pub fn cmdPersonal(
    client: *api.DiosixClient,
    args: []const [*:0]const u8,
) !void {
    if (args.len == 0) {
        printUsage();
        return;
    }
    const sub_raw = std.mem.span(args[0]);
    const sub = std.meta.stringToEnum(Subcommand, sub_raw) orelse {
        common.printFmt("Error: Unknown personal subcommand '{s}'.\n", .{
            sub_raw,
        });
        printUsage();
        return;
    };
    const allocator = std.heap.page_allocator;
    switch (sub) {
        .status => cmdStatus(allocator, client, args[1..]),
        .start => {
            var profile_opt: ?[]const u8 = null;
            var rest = args[1..];
            if (rest.len > 0 and
                !std.mem.startsWith(u8, std.mem.span(rest[0]), "-"))
            {
                profile_opt = std.mem.span(rest[0]);
                rest = rest[1..];
            }
            try launch.startProfile(allocator, client, profile_opt, rest);
        },
        .stop => _ = launch.stopActiveDesktop(client, false),
        .@"switch" => {
            if (args.len < 2) {
                common.printStr(
                    "Error: Usage: dsx personal switch <profile>\n",
                );
                return;
            }
            const next_profile = std.mem.span(args[1]);
            _ = launch.stopActiveDesktop(client, true);
            try launch.startProfile(allocator, client, next_profile, args[2..]);
        },
        .configure => try cmdConfigure(allocator, args[1..]),
        .help, .@"--help", .@"-h" => printUsage(),
    }
}

test "personal: submodules compile and config parses" {
    std.testing.refAllDecls(@This());
    _ = config;
    _ = launch;
}
