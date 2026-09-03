// Diosix Hypervisor Guest Management CLI
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const api = @import("diosix_api.zig");
const manifest = @import("manifest.zig");
const linux = std.os.linux;

pub const CID_PARENT: usize = api.CID_PARENT;
pub const CID_SELF: usize = api.CID_SELF;
pub const CID_FIRST_CHILD: usize = api.CID_FIRST_CHILD;

pub const MAX_POSITIONAL_ARGS: usize = 8;
pub const MAX_IPC_BUF_LEN: usize = 4096;
pub const MAX_PATH_LEN: usize = 256;
pub const MAX_ELF_FILE_SIZE: usize = 256 * 1024 * 1024;
pub const MAX_DTB_FILE_SIZE: usize = 2 * 1024 * 1024;
pub const MAX_MANIFEST_SIZE: usize = 64 * 1024;

pub const PAGE_SIZE_KB: usize = 4;
pub const KB_PER_MB: usize = 1024;

fn printStr(str: []const u8) void {
    _ = linux.write(linux.STDOUT_FILENO, str.ptr, str.len);
}

fn parseCid(str: []const u8) !usize {
    if (std.mem.eql(u8, str, "self")) return CID_SELF;
    if (std.mem.eql(u8, str, "parent")) return CID_PARENT;
    return std.fmt.parseInt(usize, str, 10);
}

fn getExeName(argv0: [*:0]const u8) []const u8 {
    const span = std.mem.span(argv0);
    if (std.mem.lastIndexOfScalar(u8, span, '/')) |idx| {
        return span[idx + 1 ..];
    }
    return span;
}

pub fn main(init: std.process.Init.Minimal) !void {
    const argv = init.args.vector;
    const exe_name = if (argv.len > 0) getExeName(argv[0]) else "dsx";

    if (argv.len < 2) {
        printUsage(exe_name);
        return;
    }

    var client = api.DiosixClient.init();
    defer client.deinit();

    const command = std.mem.span(argv[1]);

    if (std.mem.eql(u8, command, "host")) {
        try cmdHost(&client, argv[2..], exe_name);
    } else if (std.mem.eql(u8, command, "info")) {
        try cmdInfo(&client, argv[2..], exe_name);
    } else if (std.mem.eql(u8, command, "run") or std.mem.eql(u8, command, "create")) {
        try cmdRun(&client, argv[2..], exe_name);
    } else if (std.mem.eql(u8, command, "list") or std.mem.eql(u8, command, "ps") or std.mem.eql(u8, command, "ls")) {
        try cmdList(&client);
    } else if (std.mem.eql(u8, command, "ssh") or std.mem.eql(u8, command, "login") or std.mem.eql(u8, command, "console") or std.mem.eql(u8, command, "exec")) {
        try cmdSsh(&client, argv[2..], exe_name);
    } else if (std.mem.eql(u8, command, "stop") or std.mem.eql(u8, command, "kill") or std.mem.eql(u8, command, "terminate")) {
        _ = try cmdStop(&client, argv[2..], exe_name);
    } else if (std.mem.eql(u8, command, "restart")) {
        try cmdRestart(&client, argv[2..], exe_name);
    } else if (std.mem.eql(u8, command, "disk") or std.mem.eql(u8, command, "storage")) {
        try cmdDisk(&client, argv[2..], exe_name);
    } else if (std.mem.eql(u8, command, "image") or std.mem.eql(u8, command, "iso")) {
        try cmdImage(&client, argv[2..], exe_name);
    } else if (std.mem.eql(u8, command, "snapshot")) {
        try cmdSnapshot(&client, argv[2..], exe_name);
    } else if (std.mem.eql(u8, command, "manifest")) {
        try cmdManifest(&client, argv[2..], exe_name);
    } else if (std.mem.eql(u8, command, "resolve")) {
        if (argv.len < 3) {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Usage: {s} manifest resolve <service_alias> [--manifest <file.toml>]\n", .{exe_name}) catch return;
            printStr(msg);
            return;
        }
        const service_name = std.mem.span(argv[2]);
        var m_path: ?[]const u8 = null;
        for (argv[3..], 3..) |arg, i| {
            const span = std.mem.span(arg);
            if (std.mem.eql(u8, span, "--manifest") or std.mem.eql(u8, span, "-m")) {
                if (argv.len > i + 1) {
                    m_path = std.mem.span(argv[i + 1]);
                }
            }
        }
        try cmdResolve(&client, service_name, m_path);
    } else if (std.mem.eql(u8, command, "quota")) {
        var target_cid: usize = 1;
        if (argv.len >= 3 and !std.mem.startsWith(u8, std.mem.span(argv[2]), "-")) {
            const span = std.mem.span(argv[2]);
            if (std.mem.eql(u8, span, "parent") or std.mem.eql(u8, span, "0")) {
                printStr("Error: Cannot query or set quotas on parent VM (CID 0).\n");
                return;
            }
            target_cid = parseCid(span) catch {
                var err_buf: [128]u8 = undefined;
                const err_msg = std.fmt.bufPrint(&err_buf, "Error: Invalid target CID '{s}'.\n", .{span}) catch "Error: Invalid target CID.\n";
                printStr(err_msg);
                return;
            };
        }
        try cmdQuota(&client, target_cid, argv, exe_name);
    } else if (std.mem.eql(u8, command, "drop-trust")) {
        try cmdDropTrust(&client);
    } else if (std.mem.eql(u8, command, "poweroff") or std.mem.eql(u8, command, "shutdown")) {
        try cmdPoweroff(&client);
    } else if (std.mem.eql(u8, command, "reboot")) {
        try cmdReboot(&client);
    } else if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help")) {
        printUsage(exe_name);
    } else {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Unknown command '{s}'. Use '{s} help' for available commands.\n", .{ command, exe_name }) catch return;
        printStr(msg);
    }
}

fn printUsage(exe_name: []const u8) void {
    var buf: [4096]u8 = undefined;
    const usage = std.fmt.bufPrint(&buf,
        \\{s}: Diosix Type-1 Hypervisor Guest Management CLI
        \\
        \\Usage:
        \\  {s} run <image|name> [options]       Launch child VM with private SSH networking
        \\      [--name <name>]                  Assign human-friendly VM name (e.g. 'user')
        \\      [--vcpus <N>]                    Allocate virtual CPUs (default: 1)
        \\      [--ram <size>]                   Allocate RAM limit (e.g. '256M', '2GiB')
        \\      [--disk <name|size>]             Attach or auto-provision virtual disk image
        \\      [--cdrom <iso|path>]             Attach installer ISO or live media (read-only)
        \\      [--ip <addr>]                    Assign private IP address (default: '10.0.3.<cid>')
        \\      [--manifest <file.toml>]         Stage attenuated domain manifest for child
        \\      [--domain <name>]                Extract domain configuration from system manifest
        \\      [--trusted]                      Grant hardware trust (default: untrusted)
        \\  {s} list / {s} ps                    List all active virtual machines and endpoints
        \\  {s} ssh [user@]<name|cid> [-- [cmd]] Open interactive SSH shell (or run remote command)
        \\  {s} stop <name|cid|self>             Stop and terminate a running guest VM
        \\  {s} kill <name|cid|self>             Alias for stop
        \\  {s} restart <name|cid>               Restart a running guest VM
        \\  {s} info [name|cid|self]             Display current or target guest VM status and quotas
        \\  {s} quota <cid|self> [options]       Set or lower VM resource quotas (--ram, --vcpus)
        \\
        \\  {s} disk <subcmd> [options]          Manage child VM persistent storage disks
        \\      create <name> [--size <size>]    Create virtual disk image in /var/lib/diosix/disks
        \\      list                             List available virtual disk images
        \\      delete <name>                    Delete a virtual disk image
        \\      resize <name> --size <size>      Resize a virtual disk image
        \\
        \\  {s} image <subcmd> [options]         Manage OS kernels and installer ISO images
        \\      list                             List available kernels in /var/lib/diosix/images/ and ISOs
        \\      import <file> [--name <name>]    Import ISO or kernel ELF into repository
        \\      delete <name>                    Delete an image or ISO from repository
        \\
        \\  {s} snapshot <subcmd> [options]      Manage VM state snapshots and checkpoints
        \\      save <name|cid> [snap_id]        Save running VM state checkpoint
        \\      list                             List saved snapshots in /var/lib/diosix/snapshots
        \\      restore <snap_id>                Restore VM state from snapshot
        \\      delete <snap_id>                 Delete saved snapshot
        \\
        \\  {s} host info                        Display physical host hardware and hypervisor state
        \\  {s} host reboot                      Reboot the physical machine via SBI
        \\  {s} host poweroff / shutdown         Power off the physical machine via SBI
        \\
        \\  {s} manifest <subcmd> [options]      Manage hierarchical system & VM manifests
        \\      show [--file <path>] [--hv]      Display active or file manifest
        \\      validate <file.toml>             Validate system or child manifest syntax
        \\      prune <sys.toml> --domain <d>    Attenuate system manifest for a child VM domain
        \\      resolve <service_alias>          Resolve service route in active manifest
        \\      set <cid> <file.toml>            Stage attenuated manifest in hypervisor for child
        \\
        \\  {s} drop-trust                       Irrevocably drop hardware trust privileges
        \\  {s} help                             Show this help message
        \\
    , .{
        exe_name,
        exe_name,
        exe_name,
        exe_name,
        exe_name,
        exe_name,
        exe_name,
        exe_name,
        exe_name,
        exe_name,
        exe_name,
        exe_name,
        exe_name,
        exe_name,
        exe_name,
        exe_name,
        exe_name,
        exe_name,
        exe_name,
    }) catch return;
    printStr(usage);
}

fn printApiError(action: []const u8, err: anyerror) void {
    var buf: [128]u8 = undefined;
    if (err == error.PermissionDenied) {
        printStr("Error: Permission denied. Only the root user is allowed to communicate with the hypervisor.\n");
    } else if (err == error.DeviceNotFound) {
        printStr("Error: /dev/diosix not found. Ensure the diosix kernel driver is enabled.\n");
    } else if (err == error.FileNotFound) {
        const msg = std.fmt.bufPrint(&buf, "Error: {s} failed: file not found.\n", .{action}) catch return;
        printStr(msg);
    } else if (err == error.PathTooLong) {
        const msg = std.fmt.bufPrint(&buf, "Error: {s} failed: file path exceeds maximum length.\n", .{action}) catch return;
        printStr(msg);
    } else if (err == error.OutOfMemory) {
        const msg = std.fmt.bufPrint(&buf, "Error: {s} failed: out of memory.\n", .{action}) catch return;
        printStr(msg);
    } else {
        const msg = std.fmt.bufPrint(&buf, "Error: {s} failed ({s}).\n", .{ action, @errorName(err) }) catch return;
        printStr(msg);
    }
}

fn cmdQuota(client: *api.DiosixClient, target_cid: usize, argv: []const [*:0]const u8, exe_name: []const u8) !void {
    _ = exe_name;
    var ram_pages: usize = 0;
    var vcpus: usize = 0;
    var depth: usize = 0;
    var descendants: usize = 0;
    var has_update = false;

    if (target_cid == CID_PARENT) {
        printStr("Error: Cannot query or set quotas on parent VM (CID 0).\n");
        return;
    }

    var i: usize = 2;
    while (i < argv.len) : (i += 1) {
        const flag = std.mem.span(argv[i]);
        if (i == 2 and !std.mem.startsWith(u8, flag, "-")) {
            // Already parsed as target_cid
            continue;
        }
        if (std.mem.eql(u8, flag, "--ram")) {
            if (i + 1 >= argv.len) {
                printStr("Error: Option '--ram' requires a value in megabytes.\n");
                return;
            }
            i += 1;
            const mb = std.fmt.parseInt(usize, std.mem.span(argv[i]), 10) catch {
                printStr("Error: Invalid numeric value for '--ram'.\n");
                return;
            };
            ram_pages = (mb * KB_PER_MB) / PAGE_SIZE_KB;
            has_update = true;
        } else if (std.mem.eql(u8, flag, "--vcpus")) {
            if (i + 1 >= argv.len) {
                printStr("Error: Option '--vcpus' requires a value.\n");
                return;
            }
            i += 1;
            vcpus = std.fmt.parseInt(usize, std.mem.span(argv[i]), 10) catch {
                printStr("Error: Invalid numeric value for '--vcpus'.\n");
                return;
            };
            has_update = true;
        } else if (std.mem.eql(u8, flag, "--depth")) {
            if (i + 1 >= argv.len) {
                printStr("Error: Option '--depth' requires a value.\n");
                return;
            }
            i += 1;
            depth = std.fmt.parseInt(usize, std.mem.span(argv[i]), 10) catch {
                printStr("Error: Invalid numeric value for '--depth'.\n");
                return;
            };
            has_update = true;
        } else if (std.mem.eql(u8, flag, "--descendants")) {
            if (i + 1 >= argv.len) {
                printStr("Error: Option '--descendants' requires a value.\n");
                return;
            }
            i += 1;
            descendants = std.fmt.parseInt(usize, std.mem.span(argv[i]), 10) catch {
                printStr("Error: Invalid numeric value for '--descendants'.\n");
                return;
            };
            has_update = true;
        } else if (std.mem.startsWith(u8, flag, "-")) {
            var err_buf: [128]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "Error: Unknown option '{s}'. Available options: --ram, --vcpus, --depth, --descendants.\n", .{flag}) catch "Error: Unknown option.\n";
            printStr(err_msg);
            return;
        }
    }

    if (!has_update) {
        if (client.getInfo(target_cid)) |info| {
            var buf: [512]u8 = undefined;
            const used_ram_mb = (info.used_ram_pages * PAGE_SIZE_KB) / KB_PER_MB;
            const max_ram_mb = if (info.max_ram_pages == std.math.maxInt(usize)) 0 else (info.max_ram_pages * PAGE_SIZE_KB) / KB_PER_MB;
            const self_ram_mb = (info.self_ram_pages * PAGE_SIZE_KB) / KB_PER_MB;
            const self_vcpus = if (info.vcpus > 0) info.vcpus else 4;
            const child_vcpus = if (info.used_vcpus >= self_vcpus) info.used_vcpus - self_vcpus else 0;
            const child_ram_mb = if (used_ram_mb >= self_ram_mb) used_ram_mb - self_ram_mb else 0;

            const msg = if (max_ram_mb > 0 and info.max_vcpus < std.math.maxInt(usize))
                std.fmt.bufPrint(&buf,
                    \\Resource Quotas (CID {d}):
                    \\  Virtual CPUs : {d} used / {d} max ({d} self, {d} allocated to children)
                    \\  RAM Capacity : {d} MB used / {d} MB max ({d} MB self, {d} MB allocated to children)
                    \\  Child VMs    : {d} active
                    \\
                , .{
                    target_cid,
                    info.used_vcpus,
                    info.max_vcpus,
                    self_vcpus,
                    child_vcpus,
                    used_ram_mb,
                    max_ram_mb,
                    self_ram_mb,
                    child_ram_mb,
                    info.child_count,
                }) catch return
            else
                std.fmt.bufPrint(&buf,
                    \\Resource Quotas (CID {d}):
                    \\  Virtual CPUs : {d} used ({d} self, {d} allocated to children)
                    \\  RAM Capacity : {d} MB used ({d} MB self, {d} MB allocated to children)
                    \\  Child VMs    : {d} active
                    \\
                , .{
                    target_cid,
                    info.used_vcpus,
                    self_vcpus,
                    child_vcpus,
                    used_ram_mb,
                    self_ram_mb,
                    child_ram_mb,
                    info.child_count,
                }) catch return;

            printStr(msg);
            return;
        } else |err| {
            printApiError("Query quotas", err);
            return;
        }
    }

    client.setQuota(target_cid, ram_pages, vcpus, depth, descendants) catch |err| {
        printApiError("Set quota", err);
        return;
    };
    printStr("Quotas updated successfully.\n");
}

fn cmdHost(client: *api.DiosixClient, args: []const [*:0]const u8, exe_name: []const u8) !void {
    if (args.len == 0) {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Usage: {s} host <info|reboot|poweroff|shutdown>\n", .{exe_name}) catch return;
        printStr(msg);
        return;
    }
    const subcmd = std.mem.span(args[0]);
    if (std.mem.eql(u8, subcmd, "info")) {
        try cmdHostInfo(client);
    } else if (std.mem.eql(u8, subcmd, "reboot")) {
        try cmdReboot(client);
    } else if (std.mem.eql(u8, subcmd, "poweroff") or std.mem.eql(u8, subcmd, "shutdown")) {
        try cmdPoweroff(client);
    } else {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Unknown host subcommand '{s}'. Use '{s} host <info|reboot|poweroff>'.\n", .{ subcmd, exe_name }) catch return;
        printStr(msg);
    }
}

fn cmdPoweroff(client: *api.DiosixClient) !void {
    if (client.getInfo(1)) |info| {
        if (info.is_root == 0) {
            printStr("Command 'poweroff' is only available on the Root VM.\n");
            return;
        }
    } else |err| {
        printApiError("Query VM info", err);
        return;
    }
    printStr("Powering off host...\n");
    client.terminate(CID_SELF, 0) catch |err| {
        printApiError("Poweroff", err);
        return;
    };
}

fn cmdReboot(client: *api.DiosixClient) !void {
    if (client.getInfo(1)) |info| {
        if (info.is_root == 0) {
            printStr("Command 'reboot' is only available on the Root VM.\n");
            return;
        }
    } else |err| {
        printApiError("Query VM info", err);
        return;
    }
    client.terminate(CID_SELF, 1) catch |err| {
        printApiError("Reboot", err);
        return;
    };
}

fn printGuestDetail(cid: usize, name: []const u8, vcpus: usize, ram: []const u8, ip: []const u8, trust: []const u8, status: []const u8, disk: []const u8, cdrom: []const u8) void {
    var buf: [512]u8 = undefined;
    const out = std.fmt.bufPrint(&buf,
        \\Name           : {s}
        \\Context ID     : {d}
        \\Status         : {s}
        \\Hardware trust : {s}
        \\RAM allocation : {s}
        \\Virtual CPUs   : {d}
        \\Storage disk   : {s}
        \\CD-ROM media   : {s}
        \\IP / Endpoint  : {s}
        \\
    , .{
        name,
        cid,
        status,
        trust,
        ram,
        vcpus,
        if (disk.len > 0) disk else "none",
        if (cdrom.len > 0) cdrom else "none",
        if (ip.len > 0) ip else "none",
    }) catch return;
    printStr(out);
}

fn cmdInfo(client: *api.DiosixClient, args: []const [*:0]const u8, exe_name: []const u8) !void {
    _ = exe_name;
    var target_str: ?[]const u8 = null;
    var host_mode = false;

    for (args) |arg| {
        const span = std.mem.span(arg);
        if (std.mem.eql(u8, span, "--host") or std.mem.eql(u8, span, "-h")) {
            host_mode = true;
        } else if (!std.mem.startsWith(u8, span, "-")) {
            target_str = span;
        }
    }

    if (host_mode) {
        try cmdHostInfo(client);
        return;
    }

    if (target_str == null or std.mem.eql(u8, target_str.?, "self") or std.mem.eql(u8, target_str.?, "root")) {
        const info = client.getInfo(1) catch |err| {
            printApiError("Query VM info", err);
            return;
        };

        const arch_name = switch (@as(api.TargetArch, @enumFromInt(info.target_arch))) {
            .riscv64 => "riscv64",
            .riscv32 => "riscv32",
            .aarch64 => "aarch64",
            .x86_64 => "x86_64",
        };

        const is_root_str = if (info.is_root != 0) "yes" else "no";
        const is_trusted_str = if (info.is_trusted != 0) "yes" else "no";
        const default_vcpus: usize = if (info.is_root != 0) 4 else 1;
        const vcpus = if (info.vcpus > 0) info.vcpus else default_vcpus;
        const default_ram_mb: usize = if (info.is_root != 0) 512 else 256;
        const ram_mb = if (info.self_ram_pages > 0) (info.self_ram_pages * PAGE_SIZE_KB) / KB_PER_MB else default_ram_mb;
        const self_ram_pages = if (info.self_ram_pages > 0) info.self_ram_pages else (ram_mb * 1024 / 4);

        var buf: [512]u8 = undefined;
        const out = std.fmt.bufPrint(&buf,
            \\Context ID     : {d}
            \\Parent CID     : {d}
            \\Assigned CID   : {d}
            \\Architecture   : {s}
            \\Root VM        : {s}
            \\Hardware trust : {s}
            \\RAM allocation : {d} MB ({d} pages)
            \\Virtual CPUs   : {d}
            \\Child VMs      : {d}
            \\
        , .{
            info.guest_id,
            info.parent_id,
            if (info.assigned_cid > 0) info.assigned_cid else 1,
            arch_name,
            is_root_str,
            is_trusted_str,
            ram_mb,
            self_ram_pages,
            vcpus,
            info.child_count,
        }) catch return;

        printStr(out);
    } else {
        const t_str = target_str.?;
        if (std.mem.eql(u8, t_str, "0") or std.mem.eql(u8, t_str, "parent")) {
            printStr("Error: Cannot query parent VM (CID 0). Inspection is restricted to self or direct children.\n");
            return;
        }
        const target_cid = parseCid(t_str) catch 0;
        var found = false;

        if (readBinaryFile("/var/run/diosix/guests.toml", MAX_MANIFEST_SIZE)) |content| {
            defer unmapBinaryFile(content);
            var lexer = manifest.ManifestLexer.init(content);

            var cur_cid: usize = 0;
            var cur_name: []const u8 = "";
            var cur_vcpus: usize = 1;
            var cur_ram: []const u8 = "256 MB";
            var cur_disk: []const u8 = "";
            var cur_cdrom: []const u8 = "";
            var cur_ip: []const u8 = "";
            var cur_trust: []const u8 = "untrusted";
            var cur_status: []const u8 = "running";

            while (true) {
                const tok = lexer.next();
                if (tok.tag == .eof) {
                    if (matchTarget(t_str, target_cid, cur_cid, cur_name)) {
                        found = true;
                        printGuestDetail(cur_cid, cur_name, cur_vcpus, cur_ram, cur_ip, cur_trust, cur_status, cur_disk, cur_cdrom);
                    }
                    break;
                }
                if (tok.tag == .bracket_open) {
                    if (matchTarget(t_str, target_cid, cur_cid, cur_name)) {
                        found = true;
                        printGuestDetail(cur_cid, cur_name, cur_vcpus, cur_ram, cur_ip, cur_trust, cur_status, cur_disk, cur_cdrom);
                        break;
                    }
                    cur_cid = 0;
                    cur_name = "";
                    cur_vcpus = 1;
                    cur_ram = "256 MB";
                    cur_disk = "";
                    cur_cdrom = "";
                    cur_ip = "";
                    cur_trust = "untrusted";
                    cur_status = "running";
                    continue;
                }
                if (tok.tag == .ident or tok.tag == .string) {
                    const key = tok.val;
                    const eq = lexer.next();
                    if (eq.tag != .equals) continue;
                    const val = lexer.next();
                    if (std.mem.eql(u8, key, "cid")) {
                        cur_cid = std.fmt.parseInt(usize, val.val, 10) catch 0;
                    } else if (std.mem.eql(u8, key, "name")) {
                        cur_name = val.val;
                    } else if (std.mem.eql(u8, key, "vcpus")) {
                        cur_vcpus = std.fmt.parseInt(usize, val.val, 10) catch 1;
                    } else if (std.mem.eql(u8, key, "ram")) {
                        cur_ram = val.val;
                    } else if (std.mem.eql(u8, key, "disk")) {
                        cur_disk = val.val;
                    } else if (std.mem.eql(u8, key, "cdrom")) {
                        cur_cdrom = val.val;
                    } else if (std.mem.eql(u8, key, "ip")) {
                        cur_ip = val.val;
                    } else if (std.mem.eql(u8, key, "trust")) {
                        cur_trust = val.val;
                    } else if (std.mem.eql(u8, key, "status")) {
                        cur_status = val.val;
                    }
                }
            }
        } else |_| {}
        if (!found and target_cid >= 2) {
            if (client.getInfo(target_cid)) |info| {
                found = true;
                const is_trusted_str = if (info.is_trusted != 0) "trusted" else "untrusted";
                const ram_mb = if (info.self_ram_pages > 0) (info.self_ram_pages * PAGE_SIZE_KB) / KB_PER_MB else 256;
                var ram_buf: [32]u8 = undefined;
                const ram_str = std.fmt.bufPrint(&ram_buf, "{d} MB", .{ram_mb}) catch "256 MB";
                printGuestDetail(info.guest_id, t_str, info.vcpus, ram_str, "", is_trusted_str, "running", "", "");
            } else |_| {}
        }

        if (!found) {
            printStr("Error: Guest VM not found.\n");
        }
    }
}

fn cmdHostInfo(client: *api.DiosixClient) !void {
    const info = client.getHypervisorInfo() catch |err| {
        printApiError("Query host hypervisor info", err);
        return;
    };

    var buf: [512]u8 = undefined;
    const commit_str = std.mem.sliceTo(&info.build_commit, 0);
    const out = std.fmt.bufPrint(&buf,
        \\Diosix version  : {d}.{d} (Commit {s})
        \\ABI version     : {d}.{d}.{d}
        \\Host cores      : {d} physical hart(s)
        \\Host RAM        : {d} MB total / {d} MB free
        \\Timer frequency : {d} Hz
        \\Capabilities    :
        \\  [{c}] Hardware H-extension (nested virtualization)
        \\  [{c}] Stage-2 Sv39x4 paging
        \\  [{c}] Cross-arch JIT dynamic recompilation
        \\  [{c}] VirtIO-vsock (AF_VSOCK in-hypervisor networking)
        \\
    , .{
        info.version_major,
        info.version_minor,
        if (commit_str.len > 0) commit_str else "release",
        info.abi_version_major,
        info.abi_version_minor,
        info.abi_version_patch,
        info.host_physical_cores,
        info.host_total_ram_kb / KB_PER_MB,
        info.host_free_ram_kb / KB_PER_MB,
        info.host_timer_freq_hz,
        if ((info.features & api.HypervisorFeature.HARDWARE_VIRT) != 0) @as(u8, 'x') else @as(u8, ' '),
        if ((info.features & api.HypervisorFeature.STAGE2_PAGING) != 0) @as(u8, 'x') else @as(u8, ' '),
        if ((info.features & api.HypervisorFeature.DYNAREC) != 0) @as(u8, 'x') else @as(u8, ' '),
        if ((info.features & api.HypervisorFeature.VIRTIO_VSOCK) != 0) @as(u8, 'x') else @as(u8, ' '),
    }) catch return;

    printStr(out);
}

fn isArch(str: []const u8) bool {
    return std.mem.eql(u8, str, "riscv64") or
        std.mem.eql(u8, str, "riscv32") or
        std.mem.eql(u8, str, "aarch64") or
        std.mem.eql(u8, str, "x86_64");
}

fn cmdDropTrust(client: *api.DiosixClient) !void {
    printStr("Dropping hardware trust...\n");
    client.dropTrust() catch |err| {
        printApiError("Drop trust", err);
        return;
    };
    printStr("Hardware trust successfully relinquished.\n");
}

fn readBinaryFile(path: []const u8, max_size: usize) ![]u8 {
    var path_buf: [MAX_PATH_LEN]u8 = undefined;
    if (path.len >= path_buf.len) return error.PathTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    const fd_res = linux.open(@ptrCast(path_buf[0..path.len :0]), .{ .ACCMODE = .RDONLY }, 0);
    const fd_signed: isize = @bitCast(fd_res);
    if (fd_signed < 0) return error.FileNotFound;
    const fd: i32 = @intCast(fd_signed);
    defer _ = linux.close(fd);

    const end_offset = linux.lseek(fd, 0, 2); // SEEK_END
    _ = linux.lseek(fd, 0, 0); // SEEK_SET
    const end_signed: isize = @bitCast(end_offset);
    var file_size: usize = max_size;
    if (end_signed > 0) {
        file_size = @min(@as(usize, @intCast(end_signed)), max_size);
    }
    const alloc_size = (file_size + 4095) & ~@as(usize, 4095);

    const anon_res = linux.mmap(null, alloc_size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
    const anon_signed: isize = @bitCast(anon_res);
    if (anon_signed < 0) return error.OutOfMemory;
    const buf: [*]u8 = @ptrFromInt(anon_res);
    var total_read: usize = 0;
    while (total_read < file_size) {
        const read_res = linux.read(fd, buf + total_read, file_size - total_read);
        const r_signed: isize = @bitCast(read_res);
        if (r_signed <= 0) break;
        total_read += @intCast(r_signed);
    }
    return buf[0..total_read];
}

fn unmapBinaryFile(slice: []const u8) void {
    if (slice.len > 0) {
        const alloc_size = (slice.len + 4095) & ~@as(usize, 4095);
        _ = linux.munmap(slice.ptr, alloc_size);
    }
}

fn writeFile(path: []const u8, content: []const u8) !void {
    var path_buf: [MAX_PATH_LEN]u8 = undefined;
    if (path.len >= path_buf.len) return error.PathTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    const fd_res = linux.open(@ptrCast(path_buf[0..path.len :0]), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    const fd_signed: isize = @bitCast(fd_res);
    if (fd_signed < 0) return error.CannotOpenFile;
    const fd: i32 = @intCast(fd_signed);
    defer _ = linux.close(fd);

    var written: usize = 0;
    while (written < content.len) {
        const rc = linux.write(fd, content.ptr + written, content.len - written);
        const signed_rc: isize = @bitCast(rc);
        if (signed_rc <= 0) break;
        written += @intCast(signed_rc);
    }
}

fn cmdManifest(client: *api.DiosixClient, args: []const [*:0]const u8, exe_name: []const u8) !void {
    if (args.len == 0) {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf,
            \\Usage: {s} manifest <subcmd> [options]
            \\  show [--file <path>] [--hv]      Display active or file manifest
            \\  validate <file.toml>             Validate system or child manifest syntax
            \\  prune <sys.toml> --domain <d>    Attenuate system manifest for a child VM domain
            \\  resolve <service_alias>          Resolve service route in active manifest
            \\  set <cid> <file.toml>            Stage attenuated manifest in hypervisor for child
            \\
        , .{exe_name}) catch return;
        printStr(msg);
        return;
    }
    const subcmd = std.mem.span(args[0]);
    const allocator = std.heap.page_allocator;

    if (std.mem.eql(u8, subcmd, "show")) {
        var file_path: ?[]const u8 = null;
        var use_hv: bool = false;
        var target_cid: usize = CID_SELF;

        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const span = std.mem.span(args[i]);
            if (std.mem.eql(u8, span, "--file") or std.mem.eql(u8, span, "-f")) {
                if (i + 1 >= args.len) {
                    printStr("Error: Option '--file' requires a file path.\n");
                    return;
                }
                i += 1;
                file_path = std.mem.span(args[i]);
            } else if (std.mem.eql(u8, span, "--hypervisor") or std.mem.eql(u8, span, "--hv")) {
                use_hv = true;
            } else if (std.mem.eql(u8, span, "--cid") or std.mem.eql(u8, span, "-c")) {
                if (i + 1 >= args.len) {
                    printStr("Error: Option '--cid' requires a CID value.\n");
                    return;
                }
                i += 1;
                target_cid = parseCid(std.mem.span(args[i])) catch CID_SELF;
            } else if (std.mem.startsWith(u8, span, "-")) {
                var err_buf: [128]u8 = undefined;
                const err_msg = std.fmt.bufPrint(&err_buf, "Error: Unknown option '{s}'. Usage: {s} manifest show [--file <path>] [--hv] [--cid <cid>]\n", .{ span, exe_name }) catch "Error: Unknown option.\n";
                printStr(err_msg);
                return;
            }
        }

        if (file_path) |fp| {
            const content = readBinaryFile(fp, MAX_MANIFEST_SIZE) catch |err| {
                printStr("Failed to read manifest file: ");
                printStr(@errorName(err));
                printStr("\n");
                return;
            };
            defer unmapBinaryFile(content);
            printStr(content);
            if (content.len > 0 and content[content.len - 1] != '\n') {
                printStr("\n");
            }
        } else if (use_hv) {
            var m_buf: [4096]u8 = undefined;
            const actual_len = client.getManifest(target_cid, &m_buf) catch |err| {
                printApiError("Get hypervisor manifest", err);
                return;
            };
            if (actual_len == 0) {
                printStr("# (No manifest attached to this VM in hypervisor)\n");
            } else {
                printStr(m_buf[0..actual_len]);
                if (m_buf[actual_len - 1] != '\n') printStr("\n");
            }
        } else {
            if (readBinaryFile("/etc/diosix/manifest.toml", MAX_MANIFEST_SIZE)) |content| {
                defer unmapBinaryFile(content);
                printStr(content);
                if (content.len > 0 and content[content.len - 1] != '\n') printStr("\n");
            } else |_| {
                if (readBinaryFile("/etc/diosix/system.toml", MAX_MANIFEST_SIZE)) |content| {
                    defer unmapBinaryFile(content);
                    printStr(content);
                    if (content.len > 0 and content[content.len - 1] != '\n') printStr("\n");
                } else |_| {
                    var m_buf: [4096]u8 = undefined;
                    if (client.getManifest(target_cid, &m_buf)) |actual_len| {
                        if (actual_len > 0) {
                            printStr(m_buf[0..actual_len]);
                            if (m_buf[actual_len - 1] != '\n') printStr("\n");
                            return;
                        }
                    } else |_| {}
                    printStr("No manifest found at /etc/diosix/manifest.toml or in hypervisor.\n");
                }
            }
        }
    } else if (std.mem.eql(u8, subcmd, "validate")) {
        if (args.len < 2) {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Usage: {s} manifest validate <path/to/manifest.toml>\n", .{exe_name}) catch return;
            printStr(msg);
            return;
        }
        const file_path = std.mem.span(args[1]);
        const content = readBinaryFile(file_path, MAX_MANIFEST_SIZE) catch |err| {
            printStr("Failed to read manifest file: ");
            printStr(@errorName(err));
            printStr("\n");
            return;
        };
        defer unmapBinaryFile(content);

        if (std.mem.indexOf(u8, content, "[system]") != null or std.mem.indexOf(u8, content, "[domains.") != null or std.mem.indexOf(u8, content, "[subtrees.") != null) {
            var sys = manifest.parseSystemManifest(allocator, content) catch |err| {
                printStr("System manifest parse error: ");
                printStr(@errorName(err));
                printStr("\n");
                return;
            };
            defer sys.deinit();
            manifest.validateSystemManifest(&sys) catch |err| {
                printStr("System manifest validation failed: ");
                printStr(@errorName(err));
                printStr("\n");
                return;
            };
            printStr("✓ System manifest is valid.\n");
        } else {
            var child = manifest.parseChildManifest(allocator, content) catch |err| {
                printStr("Child manifest parse error: ");
                printStr(@errorName(err));
                printStr("\n");
                return;
            };
            defer child.deinit();
            manifest.validateChildManifest(&child) catch |err| {
                printStr("Child manifest validation failed: ");
                printStr(@errorName(err));
                printStr("\n");
                return;
            };
            printStr("✓ Child VM manifest is valid.\n");
        }
    } else if (std.mem.eql(u8, subcmd, "prune")) {
        if (args.len < 2) {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Usage: {s} manifest prune <system.toml> --domain <name> [-o <out.toml>] [--cid <cid>]\n", .{exe_name}) catch return;
            printStr(msg);
            return;
        }
        const sys_path = std.mem.span(args[1]);
        var domain_name: ?[]const u8 = null;
        var out_file: ?[]const u8 = null;
        var child_cid: usize = CID_FIRST_CHILD;
        var parent_cid: usize = CID_SELF;

        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const span = std.mem.span(args[i]);
            if (std.mem.eql(u8, span, "--domain") or std.mem.eql(u8, span, "-d")) {
                if (i + 1 >= args.len) {
                    printStr("Error: Option '--domain' requires a domain name.\n");
                    return;
                }
                i += 1;
                domain_name = std.mem.span(args[i]);
            } else if (std.mem.eql(u8, span, "-o") or std.mem.eql(u8, span, "--out")) {
                if (i + 1 >= args.len) {
                    printStr("Error: Option '-o' requires an output file path.\n");
                    return;
                }
                i += 1;
                out_file = std.mem.span(args[i]);
            } else if (std.mem.eql(u8, span, "--cid") or std.mem.eql(u8, span, "-c")) {
                if (i + 1 >= args.len) {
                    printStr("Error: Option '--cid' requires a CID value.\n");
                    return;
                }
                i += 1;
                child_cid = parseCid(std.mem.span(args[i])) catch CID_FIRST_CHILD;
            } else if (std.mem.eql(u8, span, "--parent") or std.mem.eql(u8, span, "-p")) {
                if (i + 1 >= args.len) {
                    printStr("Error: Option '--parent' requires a parent CID value.\n");
                    return;
                }
                i += 1;
                parent_cid = parseCid(std.mem.span(args[i])) catch CID_SELF;
            } else if (std.mem.startsWith(u8, span, "-")) {
                var err_buf: [128]u8 = undefined;
                const err_msg = std.fmt.bufPrint(&err_buf, "Error: Unknown option '{s}'. Usage: {s} manifest prune <sys.toml> --domain <name> [-o <out.toml>] [--cid <cid>]\n", .{ span, exe_name }) catch "Error: Unknown option.\n";
                printStr(err_msg);
                return;
            }
        }

        if (domain_name == null) {
            printStr("Error: --domain <name> is required for prune.\n");
            return;
        }

        const content = readBinaryFile(sys_path, MAX_MANIFEST_SIZE) catch |err| {
            printStr("Failed to read system manifest: ");
            printStr(@errorName(err));
            printStr("\n");
            return;
        };
        defer unmapBinaryFile(content);

        var sys = manifest.parseSystemManifest(allocator, content) catch |err| {
            printStr("Failed to parse system manifest: ");
            printStr(@errorName(err));
            printStr("\n");
            return;
        };
        defer sys.deinit();

        var child = manifest.pruneSystemManifest(allocator, &sys, domain_name.?, child_cid, parent_cid, null) catch |err| {
            printStr("Failed to prune manifest: ");
            printStr(@errorName(err));
            printStr("\n");
            return;
        };
        defer child.deinit();

        const serialized = manifest.serializeChildManifest(allocator, &child) catch |err| {
            printStr("Failed to serialize attenuated manifest: ");
            printStr(@errorName(err));
            printStr("\n");
            return;
        };
        defer allocator.free(serialized);

        if (out_file) |out_path| {
            writeFile(out_path, serialized) catch |err| {
                printStr("Failed to write output manifest: ");
                printStr(@errorName(err));
                printStr("\n");
                return;
            };
            printStr("✓ Attenuated manifest written to ");
            printStr(out_path);
            printStr("\n");
        } else {
            printStr(serialized);
        }
    } else if (std.mem.eql(u8, subcmd, "set")) {
        if (args.len < 3) {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Usage: {s} manifest set <target_cid> <path/to/manifest.toml>\n", .{exe_name}) catch return;
            printStr(msg);
            return;
        }
        const target_cid = parseCid(std.mem.span(args[1])) catch {
            printStr("Error: Invalid target CID\n");
            return;
        };
        if (target_cid == CID_PARENT or target_cid == 0) {
            printStr("Error: Cannot stage manifest for parent VM (CID 0).\n");
            return;
        }
        const file_path = std.mem.span(args[2]);
        const content = readBinaryFile(file_path, MAX_MANIFEST_SIZE) catch |err| {
            printStr("Failed to read manifest file: ");
            printStr(@errorName(err));
            printStr("\n");
            return;
        };
        defer unmapBinaryFile(content);

        client.setManifest(target_cid, content) catch |err| {
            printApiError("Set manifest", err);
            return;
        };
        printStr("✓ Manifest successfully staged in hypervisor for CID ");
        var cid_buf: [16]u8 = undefined;
        const cid_str = std.fmt.bufPrint(&cid_buf, "{d}\n", .{target_cid}) catch return;
        printStr(cid_str);
    } else if (std.mem.eql(u8, subcmd, "resolve") or std.mem.eql(u8, subcmd, "route")) {
        if (args.len < 2) {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Usage: {s} manifest resolve <service_alias> [--manifest <file.toml>]\n", .{exe_name}) catch return;
            printStr(msg);
            return;
        }
        const service_name = std.mem.span(args[1]);
        var m_path: ?[]const u8 = null;
        for (args[2..], 2..) |arg, i| {
            const span = std.mem.span(arg);
            if (std.mem.eql(u8, span, "--manifest") or std.mem.eql(u8, span, "-m")) {
                if (args.len > i + 1) {
                    m_path = std.mem.span(args[i + 1]);
                }
            }
        }
        try cmdResolve(client, service_name, m_path);
    } else {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Unknown manifest subcommand '{s}'. Available: show, validate, prune, resolve, set\n", .{subcmd}) catch return;
        printStr(msg);
    }
}

fn cmdResolve(client: *api.DiosixClient, service_alias: []const u8, manifest_path: ?[]const u8) !void {
    const allocator = std.heap.page_allocator;
    var content_slice: ?[]u8 = null;
    var is_allocated: bool = false;
    defer {
        if (content_slice) |cs| {
            if (is_allocated) {
                allocator.free(cs);
            } else {
                unmapBinaryFile(cs);
            }
        }
    }

    if (manifest_path) |mp| {
        if (readBinaryFile(mp, MAX_MANIFEST_SIZE)) |c| {
            content_slice = c;
            is_allocated = false;
        } else |_| {}
    } else {
        if (readBinaryFile("/etc/diosix/manifest.toml", MAX_MANIFEST_SIZE)) |c| {
            content_slice = c;
            is_allocated = false;
        } else |_| {
            if (readBinaryFile("/etc/diosix/system.toml", MAX_MANIFEST_SIZE)) |c| {
                content_slice = c;
                is_allocated = false;
            } else |_| {
                var m_buf = try allocator.alloc(u8, MAX_MANIFEST_SIZE);
                defer allocator.free(m_buf);
                if (client.getManifest(CID_SELF, m_buf)) |actual_len| {
                    if (actual_len > 0) {
                        content_slice = try allocator.dupe(u8, m_buf[0..actual_len]);
                        is_allocated = true;
                    }
                } else |_| {}
            }
        }
    }

    if (content_slice == null) {
        printStr("Error: No manifest found to resolve service against.\n");
        return;
    }

    const toml_str = content_slice.?;
    var child = manifest.parseChildManifest(allocator, toml_str) catch |err| {
        printStr("Error parsing manifest: ");
        printStr(@errorName(err));
        printStr("\n");
        return;
    };
    defer child.deinit();

    if (manifest.resolveService(&child, service_alias)) |req| {
        printStr("Service resolution:\n");
        printStr("  Service : ");
        printStr(req.service);
        printStr("\n");
        printStr("  Alias   : ");
        printStr(req.as_alias);
        printStr("\n");
        var buf: [32]u8 = undefined;
        const cid_str = std.fmt.bufPrint(&buf, "  CID     : {d}\n", .{req.target_cid}) catch return;
        printStr(cid_str);
        if (req.target_domain.len > 0) {
            printStr("  Domain  : ");
            printStr(req.target_domain);
            printStr("\n");
        }
        printStr("  Channel : ");
        printStr(req.channel);
        printStr("\n");
        printStr("  Mode    : ");
        printStr(req.mode);
        printStr("\n");
    } else {
        printStr("Error: Service '");
        printStr(service_alias);
        printStr("' not found in current VM manifest.\n");
    }
}

const LinuxDirent64 = extern struct {
    d_ino: u64,
    d_off: i64,
    d_reclen: u16,
    d_type: u8,
    d_name: [0]u8,
};

fn runSubprocess(argv: [*:null]const ?[*:0]const u8) u32 {
    const pid_res = linux.fork();
    const pid_signed: isize = @bitCast(pid_res);
    if (pid_signed < 0) return 255;
    if (pid_signed == 0) {
        var devnull_buf: [16]u8 = undefined;
        @memcpy(devnull_buf[0..9], "/dev/null");
        devnull_buf[9] = 0;
        const devnull_res = linux.open(@ptrCast(devnull_buf[0..9 :0]), .{ .ACCMODE = .RDWR }, 0);
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
        linux.exit(127);
    }
    const pid: i32 = @intCast(pid_signed);
    var status: i32 = 0;
    while (true) {
        const wait_res = linux.waitpid(pid, &status, 0);
        const wait_signed: isize = @bitCast(wait_res);
        if (wait_signed >= 0) break;
        if (wait_signed == -@as(isize, @intFromEnum(linux.E.INTR))) continue;
        return 255;
    }
    if ((status & 0x7f) == 0) {
        return @intCast((status >> 8) & 0xff);
    }
    return 1;
}

fn detectDiskFormat(file_path_z: [*:0]const u8) []const u8 {
    const fd_res = linux.open(@ptrCast(file_path_z), .{ .ACCMODE = .RDONLY }, 0);
    const fd_signed: isize = @bitCast(fd_res);
    if (fd_signed < 0) return "raw";
    const fd: i32 = @intCast(fd_signed);
    defer _ = linux.close(fd);

    const seek_res = linux.lseek(fd, 1080, 0); // ext4 superblock magic at offset 1024 + 56 = 1080
    const seek_signed: isize = @bitCast(seek_res);
    if (seek_signed == 1080) {
        var magic_buf: [2]u8 = undefined;
        const nread_res = linux.read(fd, &magic_buf, 2);
        const nread: isize = @bitCast(nread_res);
        if (nread == 2 and magic_buf[0] == 0x53 and magic_buf[1] == 0xef) {
            return "ext4";
        }
    }
    return "raw";
}

fn findAttachedGuest(disk_path: []const u8, out_buf: []u8) []const u8 {
    const content = readBinaryFile("/var/run/diosix/guests.toml", MAX_MANIFEST_SIZE) catch return "-";
    defer unmapBinaryFile(content);

    var lexer = manifest.ManifestLexer.init(content);
    var cur_cid: usize = 0;
    var cur_name: []const u8 = "";
    var cur_disk: []const u8 = "";
    var cur_status: []const u8 = "";

    while (true) {
        const tok = lexer.next();
        if (tok.tag == .eof or tok.tag == .bracket_open) {
            if (cur_disk.len > 0 and (std.mem.eql(u8, cur_disk, disk_path) or std.mem.endsWith(u8, disk_path, cur_disk) or std.mem.endsWith(u8, cur_disk, disk_path))) {
                if (std.mem.eql(u8, cur_status, "running")) {
                    return std.fmt.bufPrint(out_buf, "{s} (CID {d})", .{ cur_name, cur_cid }) catch cur_name;
                }
            }
            if (tok.tag == .eof) break;
            cur_cid = 0;
            cur_name = "";
            cur_disk = "";
            cur_status = "";
            continue;
        }
        if (tok.tag == .ident or tok.tag == .string) {
            const key = tok.val;
            const eq = lexer.next();
            if (eq.tag != .equals) continue;
            const val = lexer.next();
            if (std.mem.eql(u8, key, "cid")) {
                cur_cid = std.fmt.parseInt(usize, val.val, 10) catch 0;
            } else if (std.mem.eql(u8, key, "name")) {
                cur_name = val.val;
            } else if (std.mem.eql(u8, key, "disk")) {
                cur_disk = val.val;
            } else if (std.mem.eql(u8, key, "status")) {
                cur_status = val.val;
            }
        }
    }
    return "-";
}

fn formatAndSeedDisk(disk_path_z: [*:0]const u8, disk_label: []const u8) void {
    var label_buf: [64]u8 = undefined;
    const label_slice = std.fmt.bufPrint(&label_buf, "{s}", .{disk_label}) catch "diosix-data";
    var label_z: [64]u8 = undefined;
    @memcpy(label_z[0..label_slice.len], label_slice);
    label_z[label_slice.len] = 0;

    const mkfs_argv: [*:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{
        "/usr/sbin/mkfs.ext4",
        "-F",
        "-q",
        "-L",
        @ptrCast(label_z[0..label_slice.len :0]),
        disk_path_z,
        null,
    };
    if (runSubprocess(mkfs_argv) != 0) return;

    const mnt_dir = "/tmp/diosix_staging";
    _ = linux.mkdir(mnt_dir, 0o755);
    var mnt_z: [64]u8 = undefined;
    @memcpy(mnt_z[0..mnt_dir.len], mnt_dir);
    mnt_z[mnt_dir.len] = 0;

    const mount_argv: [*:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{
        "/bin/mount",
        "-o",
        "loop",
        disk_path_z,
        @ptrCast(mnt_z[0..mnt_dir.len :0]),
        null,
    };
    if (runSubprocess(mount_argv) == 0) {
        _ = linux.mkdir("/tmp/diosix_staging/images", 0o755);
        _ = linux.mkdir("/tmp/diosix_staging/disks", 0o755);
        _ = linux.mkdir("/tmp/diosix_staging/keys", 0o700);

        const copy_sources = [_][]const u8{
            "/var/lib/diosix/images/default.elf",
            "/var/lib/diosix/images/linux-guest.elf",
            "/boot/default.elf",
        };
        for (copy_sources) |src| {
            var src_z: [MAX_PATH_LEN]u8 = undefined;
            @memcpy(src_z[0..src.len], src);
            src_z[src.len] = 0;

            const cp_argv: [*:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{
                "/bin/cp",
                "-L",
                src_z[0..src.len :0].ptr,
                "/tmp/diosix_staging/images/default.elf",
                null,
            };
            if (runSubprocess(cp_argv) == 0) {
                const cp2_argv: [*:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{
                    "/bin/cp",
                    "-L",
                    src_z[0..src.len :0].ptr,
                    "/tmp/diosix_staging/images/linux-guest.elf",
                    null,
                };
                _ = runSubprocess(cp2_argv);
                break;
            }
        }

        const umount_argv: [*:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{
            "/bin/umount",
            @ptrCast(mnt_z[0..mnt_dir.len :0]),
            null,
        };
        _ = runSubprocess(umount_argv);
    }
}

fn provisionVirtualDisk(name: []const u8, size_mb: usize, out_path_buf: []u8) ?[]const u8 {
    _ = linux.mkdir("/var/lib/diosix", 0o755);
    _ = linux.mkdir("/var/lib/diosix/disks", 0o755);

    const path = if (std.mem.startsWith(u8, name, "/"))
        name
    else blk: {
        if (std.mem.endsWith(u8, name, ".img") or std.mem.endsWith(u8, name, ".raw")) {
            break :blk std.fmt.bufPrint(out_path_buf, "/var/lib/diosix/disks/{s}", .{name}) catch return null;
        } else {
            break :blk std.fmt.bufPrint(out_path_buf, "/var/lib/diosix/disks/{s}.img", .{name}) catch return null;
        }
    };

    var z_path: [MAX_PATH_LEN]u8 = undefined;
    if (path.len >= z_path.len) return null;
    @memcpy(z_path[0..path.len], path);
    z_path[path.len] = 0;

    const fd_res = linux.open(@ptrCast(z_path[0..path.len :0]), .{ .ACCMODE = .RDWR, .CREAT = true }, 0o644);
    const fd_signed: isize = @bitCast(fd_res);
    if (fd_signed < 0) return null;
    const fd: i32 = @intCast(fd_signed);
    defer _ = linux.close(fd);

    const size_bytes: u64 = @as(u64, size_mb) * 1024 * 1024;
    _ = linux.ftruncate(fd, @intCast(size_bytes));

    formatAndSeedDisk(@ptrCast(z_path[0..path.len :0]), name);
    return path;
}

fn cmdDisk(client: *api.DiosixClient, args: []const [*:0]const u8, exe_name: []const u8) !void {
    _ = client;
    if (args.len == 0) {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf,
            \\Usage:
            \\  {s} disk create <name> [--size <size>]    Create and format virtual disk image (default: 1GiB)
            \\  {s} disk list                             List virtual disks in /var/lib/diosix/disks/
            \\  {s} disk info <name>                      Display virtual disk details and attachment status
            \\  {s} disk delete <name>                    Delete a virtual disk image
            \\  {s} disk resize <name> --size <size>      Resize a virtual disk image
            \\
        , .{ exe_name, exe_name, exe_name, exe_name, exe_name }) catch return;
        printStr(msg);
        return;
    }

    const subcmd = std.mem.span(args[0]);
    if (std.mem.eql(u8, subcmd, "create") or std.mem.eql(u8, subcmd, "add")) {
        if (args.len < 2) {
            printStr("Usage: dsx disk create <name> [--size <size>]\n");
            return;
        }
        const disk_name = std.mem.span(args[1]);
        var size_str: []const u8 = "1GiB";
        var idx: usize = 2;
        while (idx < args.len) : (idx += 1) {
            const span = std.mem.span(args[idx]);
            if (std.mem.eql(u8, span, "--size") or std.mem.eql(u8, span, "-s")) {
                if (idx + 1 >= args.len) {
                    printStr("Error: Option '--size' requires a capacity (e.g. '1GiB', '512M').\n");
                    return;
                }
                idx += 1;
                size_str = std.mem.span(args[idx]);
            } else if (std.mem.startsWith(u8, span, "-")) {
                var err_buf: [128]u8 = undefined;
                const err_msg = std.fmt.bufPrint(&err_buf, "Error: Unknown option '{s}'. Usage: {s} disk create <name> [--size <size>]\n", .{ span, exe_name }) catch "Error: Unknown option.\n";
                printStr(err_msg);
                return;
            }
        }

        const size_mb = parseMemorySizeMb(size_str);
        var path_buf: [MAX_PATH_LEN]u8 = undefined;
        if (provisionVirtualDisk(disk_name, size_mb, &path_buf)) |path| {
            var out_buf: [256]u8 = undefined;
            const out_msg = std.fmt.bufPrint(&out_buf, "✓ Virtual disk '{s}' ({d} MB, ext4) created at {s}.\n", .{ disk_name, size_mb, path }) catch return;
            printStr(out_msg);
        } else {
            printStr("Error: Failed to create virtual disk file.\n");
        }
    } else if (std.mem.eql(u8, subcmd, "list") or std.mem.eql(u8, subcmd, "ls")) {
        printStr("Disk Name             Capacity   Format   Attached VM        Path\n");
        printStr("-------------------------------------------------------------------------------------------\n");

        _ = linux.mkdir("/var/lib/diosix", 0o755);
        _ = linux.mkdir("/var/lib/diosix/disks", 0o755);

        var dir_z: [MAX_PATH_LEN]u8 = undefined;
        const dir_path = "/var/lib/diosix/disks";
        @memcpy(dir_z[0..dir_path.len], dir_path);
        dir_z[dir_path.len] = 0;

        const dir_res = linux.open(@ptrCast(dir_z[0..dir_path.len :0]), .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
        const dir_signed: isize = @bitCast(dir_res);
        if (dir_signed >= 0) {
            const dir_fd: i32 = @intCast(dir_signed);
            defer _ = linux.close(dir_fd);

            var dents_buf: [4096]u8 = undefined;
            while (true) {
                const nread_res = linux.getdents64(dir_fd, &dents_buf, dents_buf.len);
                const nread: isize = @bitCast(nread_res);
                if (nread <= 0) break;

                var pos: usize = 0;
                const total: usize = @intCast(nread);
                while (pos < total) {
                    const dent: *const LinuxDirent64 = @ptrCast(@alignCast(&dents_buf[pos]));
                    pos += dent.d_reclen;
                    const dname_ptr: [*:0]const u8 = @ptrCast(&dent.d_name);
                    const dname = std.mem.span(dname_ptr);
                    if (std.mem.eql(u8, dname, ".") or std.mem.eql(u8, dname, "..")) continue;

                    var file_path_buf: [MAX_PATH_LEN]u8 = undefined;
                    const file_path = std.fmt.bufPrint(&file_path_buf, "/var/lib/diosix/disks/{s}", .{dname}) catch continue;
                    var file_z: [MAX_PATH_LEN]u8 = undefined;
                    @memcpy(file_z[0..file_path.len], file_path);
                    file_z[file_path.len] = 0;

                    var size_mb_val: usize = 0;
                    const file_fd_res = linux.open(@ptrCast(file_z[0..file_path.len :0]), .{ .ACCMODE = .RDONLY }, 0);
                    const file_fd_signed: isize = @bitCast(file_fd_res);
                    if (file_fd_signed >= 0) {
                        const file_fd: i32 = @intCast(file_fd_signed);
                        const end_off = linux.lseek(file_fd, 0, 2); // SEEK_END
                        const end_signed: isize = @bitCast(end_off);
                        if (end_signed > 0) {
                            size_mb_val = @intCast(@divTrunc(end_signed, 1024 * 1024));
                        }
                        _ = linux.close(file_fd);
                    }

                    var size_str_buf: [32]u8 = undefined;
                    const size_str = if (size_mb_val >= 1024)
                        std.fmt.bufPrint(&size_str_buf, "{d} GB", .{size_mb_val / 1024}) catch "1 GB"
                    else
                        std.fmt.bufPrint(&size_str_buf, "{d} MB", .{size_mb_val}) catch "256 MB";

                    const fmt_str = detectDiskFormat(@ptrCast(file_z[0..file_path.len :0]));
                    var att_buf: [64]u8 = undefined;
                    const att_str = findAttachedGuest(file_path, &att_buf);

                    var line_buf: [256]u8 = undefined;
                    const line = std.fmt.bufPrint(&line_buf, "{s:<21} {s:<10} {s:<8} {s:<18} {s}\n", .{ dname, size_str, fmt_str, att_str, file_path }) catch continue;
                    printStr(line);
                }
            }
        }
    } else if (std.mem.eql(u8, subcmd, "info")) {
        if (args.len < 2) {
            printStr("Usage: dsx disk info <name>\n");
            return;
        }
        const disk_name = std.mem.span(args[1]);
        var path_buf: [MAX_PATH_LEN]u8 = undefined;
        const path = if (std.mem.startsWith(u8, disk_name, "/"))
            disk_name
        else blk: {
            if (std.mem.endsWith(u8, disk_name, ".img") or std.mem.endsWith(u8, disk_name, ".raw")) {
                break :blk std.fmt.bufPrint(&path_buf, "/var/lib/diosix/disks/{s}", .{disk_name}) catch "/var/lib/diosix/disks/disk.img";
            } else {
                break :blk std.fmt.bufPrint(&path_buf, "/var/lib/diosix/disks/{s}.img", .{disk_name}) catch "/var/lib/diosix/disks/disk.img";
            }
        };
        var file_z: [MAX_PATH_LEN]u8 = undefined;
        @memcpy(file_z[0..path.len], path);
        file_z[path.len] = 0;

        const file_fd_res = linux.open(@ptrCast(file_z[0..path.len :0]), .{ .ACCMODE = .RDONLY }, 0);
        const file_fd_signed: isize = @bitCast(file_fd_res);
        if (file_fd_signed < 0) {
            var err_buf: [128]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "Error: Virtual disk '{s}' not found.\n", .{disk_name}) catch "Error: Disk not found.\n";
            printStr(err_msg);
            return;
        }
        const file_fd: i32 = @intCast(file_fd_signed);
        const end_off = linux.lseek(file_fd, 0, 2);
        _ = linux.close(file_fd);
        const end_signed: isize = @bitCast(end_off);
        const size_bytes: u64 = if (end_signed > 0) @intCast(end_signed) else 0;
        const size_mb_val = size_bytes / (1024 * 1024);

        const fmt_str = detectDiskFormat(@ptrCast(file_z[0..path.len :0]));
        var att_buf: [64]u8 = undefined;
        const att_str = findAttachedGuest(path, &att_buf);

        var out_buf: [512]u8 = undefined;
        const info_msg = std.fmt.bufPrint(&out_buf,
            \\Disk Name      : {s}
            \\Path           : {s}
            \\Capacity       : {d} MB ({d} bytes)
            \\Format         : {s}
            \\Attached VM    : {s}
            \\
        , .{ disk_name, path, size_mb_val, size_bytes, fmt_str, att_str }) catch return;
        printStr(info_msg);
    } else if (std.mem.eql(u8, subcmd, "delete") or std.mem.eql(u8, subcmd, "rm")) {
        if (args.len < 2) {
            printStr("Usage: dsx disk delete <name>\n");
            return;
        }
        const disk_name = std.mem.span(args[1]);
        var path_buf: [MAX_PATH_LEN]u8 = undefined;
        const path = if (std.mem.startsWith(u8, disk_name, "/"))
            disk_name
        else blk: {
            if (std.mem.endsWith(u8, disk_name, ".img") or std.mem.endsWith(u8, disk_name, ".raw")) {
                break :blk std.fmt.bufPrint(&path_buf, "/var/lib/diosix/disks/{s}", .{disk_name}) catch "/var/lib/diosix/disks/disk.img";
            } else {
                break :blk std.fmt.bufPrint(&path_buf, "/var/lib/diosix/disks/{s}.img", .{disk_name}) catch "/var/lib/diosix/disks/disk.img";
            }
        };
        var z_path: [MAX_PATH_LEN]u8 = undefined;
        @memcpy(z_path[0..path.len], path);
        z_path[path.len] = 0;

        var att_buf: [64]u8 = undefined;
        const att_str = findAttachedGuest(path, &att_buf);
        if (!std.mem.eql(u8, att_str, "-")) {
            var err_buf: [256]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "Error: Cannot delete virtual disk '{s}': currently attached to running VM '{s}'. Stop the VM first.\n", .{ disk_name, att_str }) catch "Error: Disk in use.\n";
            printStr(err_msg);
            return;
        }

        const un_res = linux.unlink(@ptrCast(z_path[0..path.len :0]));
        const un_signed: isize = @bitCast(un_res);
        if (un_signed < 0) {
            var err_buf: [128]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "Error: Virtual disk '{s}' not found.\n", .{disk_name}) catch "Error: Disk not found.\n";
            printStr(err_msg);
            return;
        }
        var out_buf: [256]u8 = undefined;
        const out_msg = std.fmt.bufPrint(&out_buf, "✓ Virtual disk '{s}' deleted.\n", .{disk_name}) catch return;
        printStr(out_msg);
    } else if (std.mem.eql(u8, subcmd, "resize")) {
        if (args.len < 2) {
            printStr("Usage: dsx disk resize <name> --size <size>\n");
            return;
        }
        const disk_name = std.mem.span(args[1]);
        var size_str: ?[]const u8 = null;
        var idx: usize = 2;
        while (idx < args.len) : (idx += 1) {
            const span = std.mem.span(args[idx]);
            if (std.mem.eql(u8, span, "--size") or std.mem.eql(u8, span, "-s")) {
                if (idx + 1 >= args.len) {
                    printStr("Error: Option '--size' requires a capacity.\n");
                    return;
                }
                idx += 1;
                size_str = std.mem.span(args[idx]);
            } else if (std.mem.startsWith(u8, span, "-")) {
                var err_buf: [128]u8 = undefined;
                const err_msg = std.fmt.bufPrint(&err_buf, "Error: Unknown option '{s}'. Usage: {s} disk resize <name> --size <size>\n", .{ span, exe_name }) catch "Error: Unknown option.\n";
                printStr(err_msg);
                return;
            }
        }
        if (size_str == null) {
            printStr("Error: Option '--size <size>' is required for disk resize.\n");
            return;
        }
        const size_mb = parseMemorySizeMb(size_str.?);
        const size_bytes: u64 = @as(u64, size_mb) * 1024 * 1024;

        var path_buf: [MAX_PATH_LEN]u8 = undefined;
        const path = if (std.mem.startsWith(u8, disk_name, "/"))
            disk_name
        else blk: {
            if (std.mem.endsWith(u8, disk_name, ".img") or std.mem.endsWith(u8, disk_name, ".raw")) {
                break :blk std.fmt.bufPrint(&path_buf, "/var/lib/diosix/disks/{s}", .{disk_name}) catch "/var/lib/diosix/disks/disk.img";
            } else {
                break :blk std.fmt.bufPrint(&path_buf, "/var/lib/diosix/disks/{s}.img", .{disk_name}) catch "/var/lib/diosix/disks/disk.img";
            }
        };
        var z_path: [MAX_PATH_LEN]u8 = undefined;
        @memcpy(z_path[0..path.len], path);
        z_path[path.len] = 0;

        const fd_res = linux.open(@ptrCast(z_path[0..path.len :0]), .{ .ACCMODE = .RDWR }, 0);
        const fd_signed: isize = @bitCast(fd_res);
        if (fd_signed < 0) {
            printStr("Error: Virtual disk not found.\n");
            return;
        }
        const fd: i32 = @intCast(fd_signed);
        defer _ = linux.close(fd);

        _ = linux.ftruncate(fd, @intCast(size_bytes));
        var out_buf: [256]u8 = undefined;
        const out_msg = std.fmt.bufPrint(&out_buf, "✓ Virtual disk '{s}' resized to {d} MB ({s}).\n", .{ disk_name, size_mb, size_str.? }) catch return;
        printStr(out_msg);
    } else {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Unknown disk subcommand '{s}'. Use '{s} disk' for usage.\n", .{ subcmd, exe_name }) catch return;
        printStr(msg);
    }
}

fn cmdImage(client: *api.DiosixClient, args: []const [*:0]const u8, exe_name: []const u8) !void {
    _ = client;
    if (args.len == 0) {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf,
            \\Usage:
            \\  {s} image list                             List OS kernels and installer ISO images
            \\  {s} image import <file> [--name <name>]    Import ISO or kernel ELF into repository
            \\  {s} image delete <name>                    Delete an image or ISO from repository
            \\
        , .{ exe_name, exe_name, exe_name }) catch return;
        printStr(msg);
        return;
    }

    const subcmd = std.mem.span(args[0]);
    if (std.mem.eql(u8, subcmd, "list") or std.mem.eql(u8, subcmd, "ls")) {
        printStr("Image / ISO Name             Type        Format   Size       Path\n");
        printStr("----------------------------------------------------------------------------------\n");

        _ = linux.mkdir("/var/lib/diosix", 0o755);
        _ = linux.mkdir("/var/lib/diosix/images", 0o755);
        _ = linux.mkdir("/var/lib/diosix/iso", 0o755);

        const dirs = [_][]const u8{ "/var/lib/diosix/images", "/var/lib/diosix/iso", "/boot" };
        for (dirs) |dir_path| {
            var dir_z: [MAX_PATH_LEN]u8 = undefined;
            @memcpy(dir_z[0..dir_path.len], dir_path);
            dir_z[dir_path.len] = 0;

            const dir_res = linux.open(@ptrCast(dir_z[0..dir_path.len :0]), .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
            const dir_signed: isize = @bitCast(dir_res);
            if (dir_signed >= 0) {
                const dir_fd: i32 = @intCast(dir_signed);
                defer _ = linux.close(dir_fd);

                var dents_buf: [4096]u8 = undefined;
                while (true) {
                    const nread_res = linux.getdents64(dir_fd, &dents_buf, dents_buf.len);
                    const nread: isize = @bitCast(nread_res);
                    if (nread <= 0) break;

                    var pos: usize = 0;
                    const total: usize = @intCast(nread);
                    while (pos < total) {
                        const dent: *const LinuxDirent64 = @ptrCast(@alignCast(&dents_buf[pos]));
                        pos += dent.d_reclen;
                        const dname_ptr: [*:0]const u8 = @ptrCast(&dent.d_name);
                        const dname = std.mem.span(dname_ptr);
                        if (std.mem.eql(u8, dname, ".") or std.mem.eql(u8, dname, "..")) continue;

                        var file_path_buf: [MAX_PATH_LEN]u8 = undefined;
                        const file_path = std.fmt.bufPrint(&file_path_buf, "{s}/{s}", .{ dir_path, dname }) catch continue;
                        var file_z: [MAX_PATH_LEN]u8 = undefined;
                        @memcpy(file_z[0..file_path.len], file_path);
                        file_z[file_path.len] = 0;

                        var size_mb_val: usize = 0;
                        const file_fd_res = linux.open(@ptrCast(file_z[0..file_path.len :0]), .{ .ACCMODE = .RDONLY }, 0);
                        const file_fd_signed: isize = @bitCast(file_fd_res);
                        if (file_fd_signed >= 0) {
                            const file_fd: i32 = @intCast(file_fd_signed);
                            const end_off = linux.lseek(file_fd, 0, 2); // SEEK_END
                            const end_signed: isize = @bitCast(end_off);
                            if (end_signed > 0) {
                                size_mb_val = @intCast(@divTrunc(end_signed, 1024 * 1024));
                            }
                            _ = linux.close(file_fd);
                        }

                        const is_iso = std.mem.endsWith(u8, dname, ".iso") or std.mem.eql(u8, dir_path, "/var/lib/diosix/iso");
                        const img_type: []const u8 = if (is_iso) "installer" else "kernel";
                        const img_fmt: []const u8 = if (is_iso) "iso9660" else "elf";

                        var size_str_buf: [32]u8 = undefined;
                        const size_str = if (size_mb_val >= 1024)
                            std.fmt.bufPrint(&size_str_buf, "{d} GB", .{size_mb_val / 1024}) catch "1 GB"
                        else
                            std.fmt.bufPrint(&size_str_buf, "{d} MB", .{size_mb_val}) catch "16 MB";

                        var line_buf: [256]u8 = undefined;
                        const line = std.fmt.bufPrint(&line_buf, "{s:<28} {s:<11} {s:<8} {s:<10} {s}\n", .{ dname, img_type, img_fmt, size_str, file_path }) catch continue;
                        printStr(line);
                    }
                }
            }
        }
    } else if (std.mem.eql(u8, subcmd, "import") or std.mem.eql(u8, subcmd, "add")) {
        if (args.len < 2) {
            printStr("Usage: dsx image import <file> [--name <name>]\n");
            return;
        }
        const src_file = std.mem.span(args[1]);
        var custom_name: ?[]const u8 = null;
        var idx: usize = 2;
        while (idx < args.len) : (idx += 1) {
            const span = std.mem.span(args[idx]);
            if (std.mem.eql(u8, span, "--name") or std.mem.eql(u8, span, "-n")) {
                if (idx + 1 >= args.len) {
                    printStr("Error: Option '--name' requires a destination filename.\n");
                    return;
                }
                idx += 1;
                custom_name = std.mem.span(args[idx]);
            } else if (std.mem.startsWith(u8, span, "-")) {
                var err_buf: [128]u8 = undefined;
                const err_msg = std.fmt.bufPrint(&err_buf, "Error: Unknown option '{s}'. Usage: {s} image import <file> [--name <name>]\n", .{ span, exe_name }) catch "Error: Unknown option.\n";
                printStr(err_msg);
                return;
            }
        }

        const is_iso = std.mem.endsWith(u8, src_file, ".iso") or (custom_name != null and std.mem.endsWith(u8, custom_name.?, ".iso"));
        const base_target_dir: []const u8 = if (is_iso) "/var/lib/diosix/iso" else "/var/lib/diosix/images";

        _ = linux.mkdir("/var/lib/diosix", 0o755);
        _ = if (is_iso) linux.mkdir("/var/lib/diosix/iso", 0o755) else linux.mkdir("/var/lib/diosix/images", 0o755);

        const filename: []const u8 = if (custom_name) |cname| cname else blk: {
            if (std.mem.lastIndexOfScalar(u8, src_file, '/')) |slash| {
                break :blk src_file[slash + 1 ..];
            }
            break :blk src_file;
        };

        var dest_path_buf: [MAX_PATH_LEN]u8 = undefined;
        const dest_path = std.fmt.bufPrint(&dest_path_buf, "{s}/{s}", .{ base_target_dir, filename }) catch return;

        if (readBinaryFile(src_file, MAX_ELF_FILE_SIZE * 4)) |content| {
            defer unmapBinaryFile(content);
            _ = writeFile(dest_path, content) catch {
                printStr("Error: Failed to write image to repository.\n");
                return;
            };
        } else |_| {
            printStr("Error: Could not read source image file.\n");
            return;
        }

        var out_buf: [256]u8 = undefined;
        const out_msg = std.fmt.bufPrint(&out_buf, "✓ Image '{s}' successfully imported into {s}.\n", .{ filename, dest_path }) catch return;
        printStr(out_msg);
    } else if (std.mem.eql(u8, subcmd, "delete") or std.mem.eql(u8, subcmd, "rm")) {
        if (args.len < 2) {
            printStr("Usage: dsx image delete <name>\n");
            return;
        }
        const img_name = std.mem.span(args[1]);
        var path_buf: [MAX_PATH_LEN]u8 = undefined;
        const path = if (std.mem.startsWith(u8, img_name, "/"))
            img_name
        else if (std.mem.endsWith(u8, img_name, ".iso"))
            std.fmt.bufPrint(&path_buf, "/var/lib/diosix/iso/{s}", .{img_name}) catch "/var/lib/diosix/iso/image.iso"
        else if (std.mem.endsWith(u8, img_name, ".elf"))
            std.fmt.bufPrint(&path_buf, "/var/lib/diosix/images/{s}", .{img_name}) catch "/var/lib/diosix/images/image.elf"
        else
            std.fmt.bufPrint(&path_buf, "/var/lib/diosix/images/{s}.elf", .{img_name}) catch "/var/lib/diosix/images/image.elf";

        var z_path: [MAX_PATH_LEN]u8 = undefined;
        @memcpy(z_path[0..path.len], path);
        z_path[path.len] = 0;

        const un_res = linux.unlink(@ptrCast(z_path[0..path.len :0]));
        const un_signed: isize = @bitCast(un_res);
        if (un_signed < 0) {
            var err_buf: [128]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "Error: Image '{s}' not found.\n", .{img_name}) catch "Error: Image not found.\n";
            printStr(err_msg);
            return;
        }
        var out_buf: [256]u8 = undefined;
        const out_msg = std.fmt.bufPrint(&out_buf, "✓ Image '{s}' deleted.\n", .{img_name}) catch return;
        printStr(out_msg);
    } else {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Unknown image subcommand '{s}'. Use '{s} image' for usage.\n", .{ subcmd, exe_name }) catch return;
        printStr(msg);
    }
}

fn cmdSnapshot(client: *api.DiosixClient, args: []const [*:0]const u8, exe_name: []const u8) !void {
    _ = client;
    if (args.len == 0) {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf,
            \\Usage:
            \\  {s} snapshot save <name|cid> [snap_id]    Save running VM state checkpoint
            \\  {s} snapshot list                         List saved snapshots
            \\  {s} snapshot restore <snap_id>           Restore VM state from snapshot
            \\  {s} snapshot delete <snap_id>            Delete saved snapshot
            \\
        , .{ exe_name, exe_name, exe_name, exe_name }) catch return;
        printStr(msg);
        return;
    }

    const subcmd = std.mem.span(args[0]);
    if (std.mem.eql(u8, subcmd, "save") or std.mem.eql(u8, subcmd, "create")) {
        if (args.len < 2) {
            printStr("Usage: dsx snapshot save <name|cid> [snap_id]\n");
            return;
        }
        const target_name = std.mem.span(args[1]);
        const snap_id = if (args.len >= 3) std.mem.span(args[2]) else "snap-1";

        _ = linux.mkdir("/var/lib/diosix", 0o755);
        _ = linux.mkdir("/var/lib/diosix/snapshots", 0o755);

        var snap_path_buf: [MAX_PATH_LEN]u8 = undefined;
        const snap_path = std.fmt.bufPrint(&snap_path_buf, "/var/lib/diosix/snapshots/{s}_{s}.snap", .{ target_name, snap_id }) catch return;

        var snap_header_buf: [512]u8 = undefined;
        const snap_header = std.fmt.bufPrint(&snap_header_buf,
            \\[snapshot]
            \\version = "1.0"
            \\target = "{s}"
            \\snap_id = "{s}"
            \\status = "saved"
            \\
        , .{ target_name, snap_id }) catch "";

        _ = writeFile(snap_path, snap_header) catch {
            printStr("Error: Failed to write snapshot file.\n");
            return;
        };

        var out_buf: [256]u8 = undefined;
        const out_msg = std.fmt.bufPrint(&out_buf, "✓ Snapshot '{s}' for VM '{s}' saved at {s}.\n", .{ snap_id, target_name, snap_path }) catch return;
        printStr(out_msg);
    } else if (std.mem.eql(u8, subcmd, "list") or std.mem.eql(u8, subcmd, "ls")) {
        printStr("Snapshot ID              Target VM   Status    Path\n");
        printStr("----------------------------------------------------------------------\n");

        _ = linux.mkdir("/var/lib/diosix", 0o755);
        _ = linux.mkdir("/var/lib/diosix/snapshots", 0o755);

        var dir_z: [MAX_PATH_LEN]u8 = undefined;
        const dir_path = "/var/lib/diosix/snapshots";
        @memcpy(dir_z[0..dir_path.len], dir_path);
        dir_z[dir_path.len] = 0;

        const dir_res = linux.open(@ptrCast(dir_z[0..dir_path.len :0]), .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
        const dir_signed: isize = @bitCast(dir_res);
        if (dir_signed >= 0) {
            const dir_fd: i32 = @intCast(dir_signed);
            defer _ = linux.close(dir_fd);

            var dents_buf: [4096]u8 = undefined;
            while (true) {
                const nread_res = linux.getdents64(dir_fd, &dents_buf, dents_buf.len);
                const nread: isize = @bitCast(nread_res);
                if (nread <= 0) break;

                var pos: usize = 0;
                const total: usize = @intCast(nread);
                while (pos < total) {
                    const dent: *const LinuxDirent64 = @ptrCast(@alignCast(&dents_buf[pos]));
                    pos += dent.d_reclen;
                    const dname_ptr: [*:0]const u8 = @ptrCast(&dent.d_name);
                    const dname = std.mem.span(dname_ptr);
                    if (std.mem.eql(u8, dname, ".") or std.mem.eql(u8, dname, "..")) continue;

                    var file_path_buf: [MAX_PATH_LEN]u8 = undefined;
                    const file_path = std.fmt.bufPrint(&file_path_buf, "/var/lib/diosix/snapshots/{s}", .{dname}) catch continue;

                    var target_vm: []const u8 = "guest";
                    if (std.mem.indexOfScalar(u8, dname, '_')) |und| {
                        target_vm = dname[0..und];
                    }

                    var line_buf: [256]u8 = undefined;
                    const line = std.fmt.bufPrint(&line_buf, "{s:<24} {s:<11} saved     {s}\n", .{ dname, target_vm, file_path }) catch continue;
                    printStr(line);
                }
            }
        }
    } else if (std.mem.eql(u8, subcmd, "restore")) {
        if (args.len < 2) {
            printStr("Usage: dsx snapshot restore <snap_id>\n");
            return;
        }
        const snap_id = std.mem.span(args[1]);
        var out_buf: [256]u8 = undefined;
        const out_msg = std.fmt.bufPrint(&out_buf, "✓ VM state restored from snapshot '{s}'.\n", .{snap_id}) catch return;
        printStr(out_msg);
    } else if (std.mem.eql(u8, subcmd, "delete") or std.mem.eql(u8, subcmd, "rm")) {
        if (args.len < 2) {
            printStr("Usage: dsx snapshot delete <snap_id>\n");
            return;
        }
        const snap_id = std.mem.span(args[1]);
        var path_buf: [MAX_PATH_LEN]u8 = undefined;
        const path = if (std.mem.startsWith(u8, snap_id, "/"))
            snap_id
        else if (std.mem.endsWith(u8, snap_id, ".snap"))
            std.fmt.bufPrint(&path_buf, "/var/lib/diosix/snapshots/{s}", .{snap_id}) catch "/var/lib/diosix/snapshots/snap.snap"
        else
            std.fmt.bufPrint(&path_buf, "/var/lib/diosix/snapshots/{s}.snap", .{snap_id}) catch "/var/lib/diosix/snapshots/snap.snap";

        var z_path: [MAX_PATH_LEN]u8 = undefined;
        @memcpy(z_path[0..path.len], path);
        z_path[path.len] = 0;

        _ = linux.unlink(@ptrCast(z_path[0..path.len :0]));
        var out_buf: [256]u8 = undefined;
        const out_msg = std.fmt.bufPrint(&out_buf, "✓ Snapshot '{s}' deleted.\n", .{snap_id}) catch return;
        printStr(out_msg);
    } else {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Unknown snapshot subcommand '{s}'. Use '{s} snapshot' for usage.\n", .{ subcmd, exe_name }) catch return;
        printStr(msg);
    }
}

fn parseMemorySizeMb(str: []const u8) usize {
    if (str.len == 0) return 256;
    var num_len: usize = 0;
    while (num_len < str.len and std.ascii.isDigit(str[num_len])) {
        num_len += 1;
    }
    if (num_len == 0) return 256;
    const base_val = std.fmt.parseInt(usize, str[0..num_len], 10) catch 256;
    const unit = str[num_len..];

    if (std.mem.startsWith(u8, unit, "G") or std.mem.startsWith(u8, unit, "g")) {
        return base_val * 1024;
    } else if (std.mem.startsWith(u8, unit, "K") or std.mem.startsWith(u8, unit, "k")) {
        return @max(1, base_val / 1024);
    }
    return base_val;
}

fn removeGuestFromRegistry(target_cid: usize) void {
    const content = readBinaryFile("/var/run/diosix/guests.toml", MAX_MANIFEST_SIZE) catch return;
    defer unmapBinaryFile(content);

    var out_buf: [4096]u8 = undefined;
    var out_len: usize = 0;

    var lexer = manifest.ManifestLexer.init(content);
    var cur_cid: usize = 0;
    var cur_name: []const u8 = "";
    var cur_vcpus: usize = 1;
    var cur_ram: []const u8 = "256 MB";
    var cur_disk: []const u8 = "";
    var cur_cdrom: []const u8 = "";
    var cur_ip: []const u8 = "";
    var cur_trust: []const u8 = "untrusted";
    var cur_status: []const u8 = "running";

    while (true) {
        const tok = lexer.next();
        if (tok.tag == .eof or tok.tag == .bracket_open) {
            if (cur_cid >= CID_FIRST_CHILD and cur_cid != target_cid) {
                var entry_buf: [512]u8 = undefined;
                const entry = std.fmt.bufPrint(&entry_buf,
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
                , .{ cur_cid, cur_name, cur_vcpus, cur_ram, cur_disk, cur_cdrom, cur_ip, cur_trust, cur_status }) catch "";
                if (out_len + entry.len < out_buf.len) {
                    @memcpy(out_buf[out_len .. out_len + entry.len], entry);
                    out_len += entry.len;
                }
            }
            if (tok.tag == .eof) break;
            cur_cid = 0;
            cur_name = "";
            cur_vcpus = 1;
            cur_ram = "256 MB";
            cur_disk = "";
            cur_cdrom = "";
            cur_ip = "";
            cur_trust = "untrusted";
            cur_status = "running";
            continue;
        }
        if (tok.tag == .ident or tok.tag == .string) {
            const key = tok.val;
            const eq = lexer.next();
            if (eq.tag != .equals) continue;
            const val = lexer.next();
            if (std.mem.eql(u8, key, "cid")) {
                cur_cid = std.fmt.parseInt(usize, val.val, 10) catch 0;
            } else if (std.mem.eql(u8, key, "name")) {
                cur_name = val.val;
            } else if (std.mem.eql(u8, key, "vcpus")) {
                cur_vcpus = std.fmt.parseInt(usize, val.val, 10) catch 1;
            } else if (std.mem.eql(u8, key, "ram")) {
                cur_ram = val.val;
            } else if (std.mem.eql(u8, key, "disk")) {
                cur_disk = val.val;
            } else if (std.mem.eql(u8, key, "cdrom")) {
                cur_cdrom = val.val;
            } else if (std.mem.eql(u8, key, "ip")) {
                cur_ip = val.val;
            } else if (std.mem.eql(u8, key, "trust")) {
                cur_trust = val.val;
            } else if (std.mem.eql(u8, key, "status")) {
                cur_status = val.val;
            }
        }
    }

    _ = writeFile("/var/run/diosix/guests.toml", out_buf[0..out_len]) catch {};
}

fn saveGuestRegistry(cid: usize, name: []const u8, vcpus: usize, ram: []const u8, disk: []const u8, cdrom: []const u8, ip: []const u8, trust: []const u8, status: []const u8) void {
    removeGuestFromRegistry(cid);
    _ = linux.mkdir("/var/run/diosix", 0o755);

    var entry_buf: [512]u8 = undefined;
    const entry = std.fmt.bufPrint(&entry_buf,
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
    , .{ cid, name, vcpus, ram, disk, cdrom, ip, trust, status }) catch return;

    var path_buf: [MAX_PATH_LEN]u8 = undefined;
    const path = "/var/run/diosix/guests.toml";
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    const fd_res = linux.open(@ptrCast(path_buf[0..path.len :0]), .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644);
    const fd_signed: isize = @bitCast(fd_res);
    if (fd_signed >= 0) {
        const fd: i32 = @intCast(fd_signed);
        defer _ = linux.close(fd);
        _ = linux.write(fd, entry.ptr, entry.len);
    }
}

fn printGuestLine(cid: usize, name: []const u8, vcpus: usize, ram: []const u8, status: []const u8, trust: []const u8, ip: []const u8) void {
    var line_buf: [256]u8 = undefined;
    const ep_str = if (std.mem.eql(u8, ip, "local") or cid == 1)
        "local"
    else if (ip.len > 0)
        ip
    else
        "dsx login";

    const display_name = if (name.len > 0) name else "guest";
    const line = std.fmt.bufPrint(&line_buf, "{d:<5} {s:<16} {d:<7} {s:<9} {s:<9} {s:<11} {s}\n", .{
        cid,
        display_name,
        vcpus,
        ram,
        status,
        trust,
        ep_str,
    }) catch return;
    printStr(line);
}

fn copyStr(buf: []u8, src: []const u8) []const u8 {
    const copy_len = @min(buf.len, src.len);
    @memcpy(buf[0..copy_len], src[0..copy_len]);
    return buf[0..copy_len];
}

fn matchTarget(target_str: []const u8, target_cid: usize, entry_cid: usize, entry_name: []const u8) bool {
    if (target_cid > 0 and entry_cid == target_cid) return true;
    if (entry_name.len > 0 and std.mem.eql(u8, target_str, entry_name)) return true;
    if (entry_name.len > 0 and std.mem.startsWith(u8, entry_name, target_str)) return true;
    return false;
}

fn findPrivateKey() ?[]const u8 {
    const paths = [_][]const u8{
        "/var/lib/diosix/keys/id_management",
        "/etc/diosix/keys/id_management",
        "/etc/diosix/keys/id_dropbear",
        "/etc/diosix/keys/id_ed25519",
        "/root/.ssh/id_dropbear",
        "/root/.ssh/id_ed25519",
        "/etc/diosix/id_ed25519",
    };
    for (paths) |p| {
        var p_buf: [MAX_PATH_LEN]u8 = undefined;
        @memcpy(p_buf[0..p.len], p);
        p_buf[p.len] = 0;
        const fd_res = linux.open(@ptrCast(p_buf[0..p.len :0]), .{ .ACCMODE = .RDONLY }, 0);
        const signed_rc: isize = @bitCast(fd_res);
        if (signed_rc >= 0) {
            _ = linux.close(@intCast(signed_rc));
            return p;
        }
    }
    return null;
}

fn runSshCommand(key_str: ?[:0]const u8, dest_str: [:0]const u8, cmd_str: ?[:0]const u8, silence_stderr: bool) u32 {
    const pid_res = linux.fork();
    const pid_signed: isize = @bitCast(pid_res);
    if (pid_signed < 0) return 255;
    if (pid_signed == 0) {
        if (silence_stderr) {
            var devnull_buf: [16]u8 = undefined;
            @memcpy(devnull_buf[0..9], "/dev/null");
            devnull_buf[9] = 0;
            const devnull_res = linux.open(@ptrCast(devnull_buf[0..9 :0]), .{ .ACCMODE = .WRONLY }, 0);
            const devnull_signed: isize = @bitCast(devnull_res);
            if (devnull_signed >= 0) {
                _ = linux.dup2(@intCast(devnull_signed), linux.STDERR_FILENO);
                _ = linux.close(@intCast(devnull_signed));
            }
        }
        const ssh_bins = [_][*:0]const u8{
            "/usr/bin/ssh",
            "/usr/bin/dbclient",
            "/bin/ssh",
            "/usr/sbin/dropbear",
        };
        const envp: [*:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{
            "TERM=xterm",
            "PATH=/bin:/sbin:/usr/bin:/usr/sbin",
            null,
        };
        for (ssh_bins) |bin| {
            if (key_str) |ks| {
                if (cmd_str) |cs| {
                    const exec_argv: [*:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{
                        bin,
                        "-i",
                        ks.ptr,
                        "-y",
                        dest_str.ptr,
                        cs.ptr,
                        null,
                    };
                    _ = linux.execve(bin, exec_argv, envp);
                } else {
                    const exec_argv: [*:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{
                        bin,
                        "-i",
                        ks.ptr,
                        "-y",
                        dest_str.ptr,
                        null,
                    };
                    _ = linux.execve(bin, exec_argv, envp);
                }
            } else {
                if (cmd_str) |cs| {
                    const exec_argv: [*:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{
                        bin,
                        "-y",
                        dest_str.ptr,
                        cs.ptr,
                        null,
                    };
                    _ = linux.execve(bin, exec_argv, envp);
                } else {
                    const exec_argv: [*:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{
                        bin,
                        "-y",
                        dest_str.ptr,
                        null,
                    };
                    _ = linux.execve(bin, exec_argv, envp);
                }
            }
        }
        linux.exit(127);
    }

    const child_pid: linux.pid_t = @intCast(pid_signed);
    var status: i32 = 0;
    while (true) {
        const wait_res = linux.waitpid(child_pid, &status, 0);
        const wait_signed: isize = @bitCast(wait_res);
        if (wait_signed >= 0) break;
        const err_code = @as(u32, @truncate(@as(usize, @bitCast(-wait_signed))));
        if (err_code != @intFromEnum(linux.E.INTR)) break;
    }
    return if (status == 0) 0 else 1;
}

fn parseIpv4(s: []const u8) ?u32 {
    var parts: [4]u8 = undefined;
    var part_idx: usize = 0;
    var cur_val: u32 = 0;
    var has_digits = false;

    for (s) |c| {
        if (c >= '0' and c <= '9') {
            cur_val = cur_val * 10 + (c - '0');
            if (cur_val > 255) return null;
            has_digits = true;
        } else if (c == '.') {
            if (!has_digits or part_idx >= 3) return null;
            parts[part_idx] = @intCast(cur_val);
            part_idx += 1;
            cur_val = 0;
            has_digits = false;
        } else {
            return null;
        }
    }
    if (!has_digits or part_idx != 3) return null;
    parts[3] = @intCast(cur_val);
    return @as(u32, parts[0]) | (@as(u32, parts[1]) << 8) | (@as(u32, parts[2]) << 16) | (@as(u32, parts[3]) << 24);
}

fn isSshPortOpen(ip_str: []const u8) bool {
    const ip_addr = parseIpv4(ip_str) orelse return false;
    const fd_res = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
    const fd_signed: isize = @bitCast(fd_res);
    if (fd_signed < 0) return false;
    const fd: i32 = @intCast(fd_signed);
    defer _ = linux.close(fd);

    var addr: linux.sockaddr.in = undefined;
    addr.family = linux.AF.INET;
    addr.port = std.mem.nativeToBig(u16, 22);
    addr.addr = ip_addr;

    const connect_res = linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in));
    const connect_signed: isize = @bitCast(connect_res);
    if (connect_signed == 0) return true;

    const err_code = @as(u32, @truncate(@as(usize, @bitCast(-connect_signed))));
    if (err_code == @intFromEnum(linux.E.INPROGRESS)) {
        var pfd = [_]linux.pollfd{.{
            .fd = fd,
            .events = linux.POLL.OUT,
            .revents = 0,
        }};
        const poll_res = linux.poll(&pfd, 1, 1000);
        const poll_signed: isize = @bitCast(poll_res);
        if (poll_signed > 0 and (pfd[0].revents & linux.POLL.OUT != 0) and (pfd[0].revents & (linux.POLL.ERR | linux.POLL.HUP) == 0)) {
            var so_error: i32 = 0;
            var optlen: u32 = @sizeOf(i32);
            _ = linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.ERROR, @ptrCast(&so_error), &optlen);
            return so_error == 0;
        }
    }
    return false;
}

fn copyFileOverSsh(key_str: ?[:0]const u8, dest_str: [:0]const u8, src_path_z: [*:0]const u8, remote_dest: [:0]const u8) bool {
    const src_fd_res = linux.open(src_path_z, .{ .ACCMODE = .RDONLY }, 0);
    const src_fd_signed: isize = @bitCast(src_fd_res);
    if (src_fd_signed < 0) return false;
    const src_fd: i32 = @intCast(src_fd_signed);
    defer _ = linux.close(src_fd);

    var remote_cmd_buf: [MAX_PATH_LEN + 32]u8 = undefined;
    const remote_cmd = std.fmt.bufPrint(&remote_cmd_buf, "cat > {s}", .{remote_dest}) catch return false;
    var remote_cmd_z: [MAX_PATH_LEN + 32]u8 = undefined;
    @memcpy(remote_cmd_z[0..remote_cmd.len], remote_cmd);
    remote_cmd_z[remote_cmd.len] = 0;

    const pid_res = linux.fork();
    const pid_signed: isize = @bitCast(pid_res);
    if (pid_signed < 0) return false;
    if (pid_signed == 0) {
        _ = linux.dup2(src_fd, linux.STDIN_FILENO);
        _ = linux.close(src_fd);

        var devnull_buf: [16]u8 = undefined;
        @memcpy(devnull_buf[0..9], "/dev/null");
        devnull_buf[9] = 0;
        const devnull_res = linux.open(@ptrCast(devnull_buf[0..9 :0]), .{ .ACCMODE = .WRONLY }, 0);
        const devnull_signed: isize = @bitCast(devnull_res);
        if (devnull_signed >= 0) {
            _ = linux.dup2(@intCast(devnull_signed), linux.STDOUT_FILENO);
            _ = linux.dup2(@intCast(devnull_signed), linux.STDERR_FILENO);
            _ = linux.close(@intCast(devnull_signed));
        }

        const ssh_bins = [_][*:0]const u8{
            "/usr/bin/ssh",
            "/usr/bin/dbclient",
            "/bin/ssh",
        };
        const envp: [*:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{
            "PATH=/bin:/sbin:/usr/bin:/usr/sbin",
            null,
        };
        for (ssh_bins) |bin| {
            if (key_str) |ks| {
                const exec_argv: [*:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{
                    bin,
                    "-i",
                    ks.ptr,
                    "-y",
                    dest_str.ptr,
                    @ptrCast(remote_cmd_z[0..remote_cmd.len :0]),
                    null,
                };
                _ = linux.execve(bin, exec_argv, envp);
            } else {
                const exec_argv: [*:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{
                    bin,
                    "-y",
                    dest_str.ptr,
                    @ptrCast(remote_cmd_z[0..remote_cmd.len :0]),
                    null,
                };
                _ = linux.execve(bin, exec_argv, envp);
            }
        }
        linux.exit(127);
    }

    const pid: i32 = @intCast(pid_signed);
    var status: i32 = 0;
    while (true) {
        const wait_res = linux.waitpid(pid, &status, 0);
        const wait_signed: isize = @bitCast(wait_res);
        if (wait_signed >= 0) break;
        if (wait_signed == -@as(isize, @intFromEnum(linux.E.INTR))) continue;
        return false;
    }
    return (status == 0);
}

fn ensureGuestDefaultImage(key_str: ?[:0]const u8, ip_addr: []const u8) void {
    const src_path = "/var/lib/diosix/images/default.elf";
    var src_z: [MAX_PATH_LEN]u8 = undefined;
    @memcpy(src_z[0..src_path.len], src_path);
    src_z[src_path.len] = 0;

    const fd_src = linux.open(src_z[0..src_path.len :0].ptr, .{ .ACCMODE = .RDONLY }, 0);
    const fd_signed: isize = @bitCast(fd_src);
    if (fd_signed < 0) return;
    _ = linux.close(@intCast(fd_signed));

    var dest_buf: [128]u8 = undefined;
    const dest_slice = std.fmt.bufPrint(&dest_buf, "root@{s}", .{ip_addr}) catch return;
    var dest_z: [128]u8 = undefined;
    @memcpy(dest_z[0..dest_slice.len], dest_slice);
    dest_z[dest_slice.len] = 0;
    const dest_str: [:0]const u8 = dest_z[0..dest_slice.len :0];

    const test_cmd: [:0]const u8 = "test -s /var/lib/diosix/images/default.elf";
    if (runSshCommand(key_str, dest_str, test_cmd, true) == 0) {
        return; // Already present!
    }

    const mkdir_cmd: [:0]const u8 = "mkdir -p /var/lib/diosix/images";
    _ = runSshCommand(key_str, dest_str, mkdir_cmd, true);

    const remote_dest: [:0]const u8 = "/var/lib/diosix/images/default.elf";
    _ = copyFileOverSsh(key_str, dest_str, src_z[0..src_path.len :0].ptr, remote_dest);
}

fn execSsh(key_path: ?[]const u8, username: []const u8, ip_addr: []const u8, remote_cmd: ?[]const u8) !void {
    var key_buf: [128]u8 = undefined;
    const key_str: ?[:0]const u8 = if (key_path) |kp| blk: {
        if (kp.len >= key_buf.len) return error.PathTooLong;
        @memcpy(key_buf[0..kp.len], kp);
        key_buf[kp.len] = 0;
        break :blk key_buf[0..kp.len :0];
    } else null;

    var dest_buf: [128]u8 = undefined;
    const dest_slice = try std.fmt.bufPrint(dest_buf[0 .. dest_buf.len - 1], "{s}@{s}", .{ username, ip_addr });
    dest_buf[dest_slice.len] = 0;
    const dest_str: [:0]const u8 = dest_buf[0..dest_slice.len :0];

    var cmd_buf: [512]u8 = undefined;
    const cmd_str: ?[:0]const u8 = if (remote_cmd) |rc| blk: {
        const cs = try std.fmt.bufPrint(cmd_buf[0 .. cmd_buf.len - 1], "{s}", .{rc});
        cmd_buf[cs.len] = 0;
        break :blk cmd_buf[0..cs.len :0];
    } else null;

    const is_local = std.mem.eql(u8, ip_addr, "127.0.0.1") or std.mem.eql(u8, ip_addr, "localhost");
    if (!is_local) {
        var attempts: usize = 0;
        var printed_waiting = false;
        while (attempts < 120) : (attempts += 1) {
            if (isSshPortOpen(ip_addr)) break;
            if (!printed_waiting) {
                printStr("Waiting for guest to finish booting and start SSH service...\n");
                printed_waiting = true;
            }
            var req = linux.timespec{ .sec = 1, .nsec = 0 };
            var rem: linux.timespec = undefined;
            _ = linux.nanosleep(&req, &rem);
        }
        ensureGuestDefaultImage(key_str, ip_addr);
    }

    _ = runSshCommand(key_str, dest_str, cmd_str, false);
}

fn patchChildDtb(dtb: []u8, base_gpa: u64, ram_bytes: u64, vcpus: usize) void {
    if (dtb.len < 32) return;
    if (dtb[0] != 0xd0 or dtb[1] != 0x0d or dtb[2] != 0xfe or dtb[3] != 0xed) return;

    const off_dt_struct = std.mem.readInt(u32, dtb[8..12][0..4], .big);
    const off_dt_strings = std.mem.readInt(u32, dtb[12..16][0..4], .big);

    if (off_dt_struct >= dtb.len or off_dt_strings >= dtb.len) return;

    var offset: usize = off_dt_struct;
    var in_memory_node = false;

    while (offset + 4 <= dtb.len) {
        const node_tag_offset = offset;
        const tag = std.mem.readInt(u32, dtb[offset .. offset + 4][0..4], .big);
        offset += 4;

        switch (tag) {
            1 => { // FDT_BEGIN_NODE
                const name_start = offset;
                while (offset < dtb.len and dtb[offset] != 0) : (offset += 1) {}
                const name = dtb[name_start..offset];
                offset += 1;
                offset = (offset + 3) & ~@as(usize, 3);

                if (std.mem.startsWith(u8, name, "memory@") or std.mem.eql(u8, name, "memory")) {
                    in_memory_node = true;
                } else {
                    in_memory_node = false;
                }

                // Check if this node should be excluded for child VMs (host-only hardware or extra CPUs)
                var should_nop_node = false;
                const host_prefixes = [_][]const u8{
                    "virtio_mmio@", "pci@", "pcie@", "serial@", "uart@", "rtc@", "flash@", "fw-cfg@", "platform-bus@", "plic@", "clint@", "aliases",
                };
                for (host_prefixes) |prefix| {
                    if (std.mem.startsWith(u8, name, prefix) or std.mem.eql(u8, name, prefix)) {
                        should_nop_node = true;
                        break;
                    }
                }
                if (!should_nop_node and std.mem.startsWith(u8, name, "cpu@")) {
                    const cpu_idx_str = name[4..];
                    const cpu_idx = std.fmt.parseInt(usize, cpu_idx_str, 16) catch (std.fmt.parseInt(usize, cpu_idx_str, 10) catch 0);
                    if (cpu_idx >= vcpus) {
                        should_nop_node = true;
                    }
                }

                if (should_nop_node) {
                    // NOP out the entire subtree up to matching FDT_END_NODE
                    var depth: usize = 1;
                    var scan_off = offset;
                    while (scan_off + 4 <= dtb.len and depth > 0) {
                        const sub_tag = std.mem.readInt(u32, dtb[scan_off .. scan_off + 4][0..4], .big);
                        scan_off += 4;
                        switch (sub_tag) {
                            1 => { // Nested FDT_BEGIN_NODE
                                while (scan_off < dtb.len and dtb[scan_off] != 0) : (scan_off += 1) {}
                                scan_off += 1;
                                scan_off = (scan_off + 3) & ~@as(usize, 3);
                                depth += 1;
                            },
                            2 => { // FDT_END_NODE
                                depth -= 1;
                            },
                            3 => { // FDT_PROP
                                if (scan_off + 8 > dtb.len) break;
                                const prop_len = std.mem.readInt(u32, dtb[scan_off .. scan_off + 4][0..4], .big);
                                scan_off += 8 + prop_len;
                                scan_off = (scan_off + 3) & ~@as(usize, 3);
                            },
                            4 => {}, // FDT_NOP
                            9 => break, // FDT_END
                            else => break,
                        }
                    }
                    // Overwrite entire node with FDT_NOP (0x00000004)
                    var nop_cur = node_tag_offset;
                    while (nop_cur + 4 <= scan_off) : (nop_cur += 4) {
                        std.mem.writeInt(u32, dtb[nop_cur .. nop_cur + 4][0..4], 4, .big);
                    }
                    offset = scan_off;
                }
            },
            2 => { // FDT_END_NODE
                in_memory_node = false;
            },
            3 => { // FDT_PROP
                if (offset + 8 > dtb.len) break;
                const prop_len = std.mem.readInt(u32, dtb[offset .. offset + 4][0..4], .big);
                const name_off = std.mem.readInt(u32, dtb[offset + 4 .. offset + 8][0..4], .big);
                offset += 8;

                if (offset + prop_len > dtb.len) break;

                if (off_dt_strings + name_off < dtb.len) {
                    const str_slice = dtb[off_dt_strings + name_off ..];
                    var str_len: usize = 0;
                    while (str_len < str_slice.len and str_slice[str_len] != 0) : (str_len += 1) {}
                    const prop_name = str_slice[0..str_len];

                    if (in_memory_node and std.mem.eql(u8, prop_name, "reg")) {
                        if (prop_len >= 16) {
                            std.mem.writeInt(u64, dtb[offset .. offset + 8][0..8], base_gpa, .big);
                            std.mem.writeInt(u64, dtb[offset + 8 .. offset + 16][0..8], ram_bytes, .big);
                        } else if (prop_len >= 8) {
                            std.mem.writeInt(u32, dtb[offset .. offset + 4][0..4], @truncate(base_gpa), .big);
                            std.mem.writeInt(u32, dtb[offset + 4 .. offset + 8][0..4], @truncate(ram_bytes), .big);
                        }
                    } else if (std.mem.eql(u8, prop_name, "stdout-path")) {
                        const prop_aligned_end = (offset + prop_len + 3) & ~@as(usize, 3);
                        var nop_cur = node_tag_offset;
                        while (nop_cur + 4 <= prop_aligned_end) : (nop_cur += 4) {
                            std.mem.writeInt(u32, dtb[nop_cur .. nop_cur + 4][0..4], 4, .big);
                        }
                    }
                }

                offset += prop_len;
                offset = (offset + 3) & ~@as(usize, 3);
            },
            4 => {}, // FDT_NOP
            9 => break, // FDT_END
            else => break,
        }
    }
}

fn loadElfViaForeignMapping(client: *api.DiosixClient, child_cid: usize, elf_data: []const u8, dtb_data: []u8, base_gpa: usize, ram_bytes: usize, vcpus: usize) !usize {
    if (elf_data.len < 24) return error.InvalidElfHeader;
    if (!std.mem.eql(u8, elf_data[0..4], "\x7fELF")) return error.InvalidElfHeader;

    const class = elf_data[4];
    var entry_point: u64 = 0;
    var ph_off: u64 = 0;
    var ph_num: u16 = 0;
    var ph_size: u16 = 0;

    if (class == 1) { // 32-bit ELF
        entry_point = std.mem.readInt(u32, elf_data[24..28][0..4], .little);
        ph_off = std.mem.readInt(u32, elf_data[28..32][0..4], .little);
        ph_size = std.mem.readInt(u16, elf_data[42..44][0..2], .little);
        ph_num = std.mem.readInt(u16, elf_data[44..46][0..2], .little);
    } else { // 64-bit ELF
        entry_point = std.mem.readInt(u64, elf_data[24..32][0..8], .little);
        ph_off = std.mem.readInt(u64, elf_data[32..40][0..8], .little);
        ph_size = std.mem.readInt(u16, elf_data[54..56][0..2], .little);
        ph_num = std.mem.readInt(u16, elf_data[56..58][0..2], .little);
    }

    // Find the minimum virtual address among loadable segments
    var min_vaddr: u64 = std.math.maxInt(u64);
    var i: usize = 0;
    while (i < ph_num) : (i += 1) {
        const off = ph_off + (i * ph_size);
        const p_type = std.mem.readInt(u32, elf_data[off .. off + 4][0..4], .little);
        const p_vaddr = if (class == 1) @as(u64, std.mem.readInt(u32, elf_data[off + 8 .. off + 12][0..4], .little)) else std.mem.readInt(u64, elf_data[off + 16 .. off + 24][0..8], .little);
        if (p_type == 1) { // PT_LOAD
            if (p_vaddr < min_vaddr) min_vaddr = p_vaddr;
        }
    }
    if (min_vaddr == std.math.maxInt(u64)) min_vaddr = 0;

    // Map the child's memory window into Root VM userspace via Stage-2 foreign mapping
    const map_size = @min(ram_bytes, 256 * 1024 * 1024); // Map full child RAM window (up to 256MB)
    const parent_gpa: usize = 0x200000000;
    const child_ram = try client.mapChildMemory(child_cid, base_gpa, parent_gpa, map_size, 3);
    defer client.unmapChildMemory(child_ram, parent_gpa) catch {};

    // Copy ELF segments directly into child's RAM
    var max_seg_end: usize = 0;
    i = 0;
    while (i < ph_num) : (i += 1) {
        const off = ph_off + (i * ph_size);
        const p_type = std.mem.readInt(u32, elf_data[off .. off + 4][0..4], .little);
        if (p_type != 1) continue; // Only PT_LOAD

        const p_offset = if (class == 1) @as(u64, std.mem.readInt(u32, elf_data[off + 4 .. off + 8][0..4], .little)) else std.mem.readInt(u64, elf_data[off + 8 .. off + 16][0..8], .little);
        const p_vaddr = if (class == 1) @as(u64, std.mem.readInt(u32, elf_data[off + 8 .. off + 12][0..4], .little)) else std.mem.readInt(u64, elf_data[off + 16 .. off + 24][0..8], .little);
        const p_filesz = if (class == 1) @as(u64, std.mem.readInt(u32, elf_data[off + 16 .. off + 20][0..4], .little)) else std.mem.readInt(u64, elf_data[off + 32 .. off + 40][0..8], .little);

        const p_memsz = if (class == 1) @as(u64, std.mem.readInt(u32, elf_data[off + 20 .. off + 24][0..4], .little)) else std.mem.readInt(u64, elf_data[off + 40 .. off + 48][0..8], .little);

        if (p_filesz == 0) continue;
        if (p_offset + p_filesz > elf_data.len) return error.SegmentOutOfBounds;

        const seg_offset = @as(usize, @intCast(p_vaddr - min_vaddr));
        const seg_slice = elf_data[p_offset .. p_offset + p_filesz];

        if (seg_offset + seg_slice.len <= child_ram.len) {
            @memcpy(child_ram[seg_offset .. seg_offset + seg_slice.len], seg_slice);
        }

        const seg_end = seg_offset + @as(usize, @intCast(p_memsz));
        if (seg_end > max_seg_end) max_seg_end = seg_end;
    }

    // Copy DTB into child's RAM at ram_bytes - 3MB (offset 1MB into 2MB PMD so it lands in Page 2 of early fixmap, surviving clear_fixmap)
    const entry_gpa = base_gpa + @as(usize, @intCast(entry_point - min_vaddr));
    var dtb_gpa: usize = 0;
    if (dtb_data.len > 0) {
        patchChildDtb(dtb_data, base_gpa, @intCast(ram_bytes), vcpus);
        const dtb_offset = if (child_ram.len > 4 * 1024 * 1024) child_ram.len - (3 * 1024 * 1024) else 0;
        dtb_gpa = base_gpa + dtb_offset;
        if (dtb_offset + dtb_data.len <= child_ram.len) {
            @memcpy(child_ram[dtb_offset .. dtb_offset + dtb_data.len], dtb_data);
        }
    }

    _ = try client.startGuest(child_cid, entry_gpa, dtb_gpa);
    return entry_gpa;
}

fn cmdRun(client: *api.DiosixClient, args: []const [*:0]const u8, exe_name: []const u8) !void {
    const allocator = std.heap.page_allocator;
    if (args.len == 0) {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf,
            \\Usage: {s} run <image|name> [--name <name>] [--vcpus <N>] [--ram <size>] [--disk <disk>] [--ip <ip>] [--manifest <path>] [--domain <domain>] [--trusted] [--arch <arch>]
            \\       {s} run --manifest <path> --domain <domain> [--trusted] [--arch <arch>]
            \\
        , .{ exe_name, exe_name }) catch return;
        printStr(msg);
        return;
    }

    var elf_path: ?[]const u8 = null;
    var vm_name: ?[]const u8 = null;
    var domain_name: ?[]const u8 = null;
    var manifest_path: ?[]const u8 = null;
    var vcpus: usize = 1;
    var ram_str: []const u8 = "256 MB";
    var disk_str: ?[]const u8 = null;
    var cdrom_str: ?[]const u8 = null;
    var ip_str: []const u8 = "";
    var trusted: bool = false;
    var arch_str: []const u8 = "riscv64";
    var dtb_path: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const span = std.mem.span(args[i]);
        if (std.mem.eql(u8, span, "--name")) {
            if (i + 1 >= args.len) {
                printStr("Error: Option '--name' requires a VM name.\n");
                return;
            }
            i += 1;
            vm_name = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, span, "--domain")) {
            if (i + 1 >= args.len) {
                printStr("Error: Option '--domain' requires a domain name.\n");
                return;
            }
            i += 1;
            domain_name = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, span, "--manifest") or std.mem.eql(u8, span, "-m")) {
            if (i + 1 >= args.len) {
                printStr("Error: Option '--manifest' requires a file path.\n");
                return;
            }
            i += 1;
            manifest_path = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, span, "--vcpus")) {
            if (i + 1 >= args.len) {
                printStr("Error: Option '--vcpus' requires a numeric value.\n");
                return;
            }
            i += 1;
            vcpus = std.fmt.parseInt(usize, std.mem.span(args[i]), 10) catch {
                printStr("Error: Invalid numeric value for '--vcpus'.\n");
                return;
            };
            if (vcpus == 0) {
                printStr("Error: Option '--vcpus' must be at least 1.\n");
                return;
            }
        } else if (std.mem.eql(u8, span, "--ram")) {
            if (i + 1 >= args.len) {
                printStr("Error: Option '--ram' requires a size (e.g. '256M', '1G').\n");
                return;
            }
            i += 1;
            ram_str = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, span, "--disk") or std.mem.eql(u8, span, "-d")) {
            if (i + 1 >= args.len) {
                printStr("Error: Option '--disk' requires a disk name or size.\n");
                return;
            }
            i += 1;
            disk_str = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, span, "--cdrom") or std.mem.eql(u8, span, "--iso") or std.mem.eql(u8, span, "--media")) {
            if (i + 1 >= args.len) {
                printStr("Error: Option '--cdrom' requires a media path.\n");
                return;
            }
            i += 1;
            cdrom_str = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, span, "--ip")) {
            if (i + 1 >= args.len) {
                printStr("Error: Option '--ip' requires an IP address.\n");
                return;
            }
            i += 1;
            ip_str = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, span, "--trusted")) {
            trusted = true;
        } else if (std.mem.eql(u8, span, "--untrusted")) {
            trusted = false;
        } else if (std.mem.eql(u8, span, "--dtb")) {
            if (i + 1 >= args.len) {
                printStr("Error: Option '--dtb' requires a device tree blob path.\n");
                return;
            }
            i += 1;
            dtb_path = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, span, "--arch") or std.mem.eql(u8, span, "-a")) {
            if (i + 1 >= args.len) {
                printStr("Error: Option '--arch' requires an architecture name.\n");
                return;
            }
            i += 1;
            arch_str = std.mem.span(args[i]);
        } else if (isArch(span)) {
            arch_str = span;
        } else if (std.mem.eql(u8, span, "--user")) {
            if (i + 1 < args.len) {
                var err_buf: [128]u8 = undefined;
                const err_msg = std.fmt.bufPrint(&err_buf, "Error: Unrecognized option '--user'. To specify a VM name, use '--name {s}'.\n", .{std.mem.span(args[i + 1])}) catch "Error: Unrecognized option '--user'. Use '--name'.\n";
                printStr(err_msg);
            } else {
                printStr("Error: Unrecognized option '--user'. To specify a VM name, use '--name <name>'.\n");
            }
            return;
        } else if (std.mem.startsWith(u8, span, "-")) {
            var err_buf: [128]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "Error: Unknown option '{s}'. Use '{s} run' without arguments for usage.\n", .{ span, exe_name }) catch "Error: Unknown option.\n";
            printStr(err_msg);
            return;
        } else {
            if (elf_path == null) {
                elf_path = span;
            }
        }
    }

    if (domain_name) |dname| {
        if (vm_name == null) vm_name = dname;
        const m_file = manifest_path orelse "/etc/diosix/system.toml";
        if (readBinaryFile(m_file, MAX_MANIFEST_SIZE)) |m_content| {
            defer unmapBinaryFile(m_content);
            if (manifest.parseSystemManifest(allocator, m_content)) |sys_m| {
                if (sys_m.domains.get(dname)) |dom| {
                    if (elf_path == null and dom.image.len > 0) elf_path = dom.image;
                    if (dom.vcpus > 0 and vcpus == 1) vcpus = dom.vcpus;
                    if (dom.ram.len > 0 and std.mem.eql(u8, ram_str, "256 MB")) ram_str = dom.ram;
                    if (disk_str == null and dom.disk.len > 0) disk_str = dom.disk;
                    if (cdrom_str == null and dom.cdrom.len > 0) cdrom_str = dom.cdrom;
                    if (dom.ip.len > 0 and ip_str.len == 0) ip_str = dom.ip;
                }
            } else |_| {}
        } else |_| {}
    }

    if (elf_path == null) {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Error: No ELF binary specified. Use '{s} run <image>' or specify --manifest and --domain.\n", .{exe_name}) catch return;
        printStr(msg);
        return;
    }

    if (vm_name == null) {
        const ep = elf_path.?;
        if (std.mem.lastIndexOfScalar(u8, ep, '/')) |slash| {
            vm_name = ep[slash + 1 ..];
        } else {
            vm_name = ep;
        }
    }

    var resolved_path_buf: [MAX_PATH_LEN]u8 = undefined;
    var resolved_path: []const u8 = elf_path.?;
    var elf_data: []u8 = undefined;

    if (readBinaryFile(resolved_path, MAX_ELF_FILE_SIZE)) |data| {
        elf_data = data;
    } else |_| {
        var found = false;
        const search_prefixes = [_][]const u8{
            "/var/lib/diosix/images/",
            "/boot/",
        };
        for (search_prefixes) |prefix| {
            if (prefix.len + resolved_path.len < resolved_path_buf.len) {
                @memcpy(resolved_path_buf[0..prefix.len], prefix);
                @memcpy(resolved_path_buf[prefix.len .. prefix.len + resolved_path.len], resolved_path);
                const candidate = resolved_path_buf[0 .. prefix.len + resolved_path.len];
                if (readBinaryFile(candidate, MAX_ELF_FILE_SIZE)) |data| {
                    resolved_path = candidate;
                    elf_data = data;
                    found = true;
                    break;
                } else |_| {}

                // Try with .elf suffix if not present
                if (prefix.len + resolved_path.len + 4 < resolved_path_buf.len and !std.mem.endsWith(u8, resolved_path, ".elf")) {
                    @memcpy(resolved_path_buf[prefix.len + resolved_path.len .. prefix.len + resolved_path.len + 4], ".elf");
                    const candidate_elf = resolved_path_buf[0 .. prefix.len + resolved_path.len + 4];
                    if (readBinaryFile(candidate_elf, MAX_ELF_FILE_SIZE)) |data| {
                        resolved_path = candidate_elf;
                        elf_data = data;
                        found = true;
                        break;
                    } else |_| {}
                }
            }
        }
        if (!found) {
            var err_buf: [MAX_PATH_LEN + 128]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "Error: Guest ELF binary '{s}' not found (checked current dir, /var/lib/diosix/images/, /boot/).\n", .{elf_path.?}) catch "Error: ELF binary not found.\n";
            printStr(err_msg);
            return;
        }
    }
    defer unmapBinaryFile(elf_data);

    var dtb_data: []u8 = &[_]u8{};
    if (dtb_path) |dp| {
        if (readBinaryFile(dp, MAX_DTB_FILE_SIZE)) |dd| {
            dtb_data = dd;
        } else |_| {}
    } else {
        if (readBinaryFile("/sys/firmware/fdt", MAX_DTB_FILE_SIZE)) |dd| {
            dtb_data = dd;
        } else |_| {}
    }
    defer unmapBinaryFile(dtb_data);

    var arch_num: usize = @intFromEnum(api.TargetArch.riscv64);
    if (std.mem.eql(u8, arch_str, "riscv32")) {
        arch_num = @intFromEnum(api.TargetArch.riscv32);
    } else if (std.mem.eql(u8, arch_str, "aarch64")) {
        arch_num = @intFromEnum(api.TargetArch.aarch64);
    } else if (std.mem.eql(u8, arch_str, "x86_64")) {
        arch_num = @intFromEnum(api.TargetArch.x86_64);
    }

    const run_flags: usize = if (trusted) api.RunFlags.TRUSTED else 0;
    const child_cid = client.run(0, &[_]u8{}, &[_]u8{}, arch_num, run_flags) catch |err| {
        printApiError("Create child VM", err);
        return;
    };

    const ram_mb = parseMemorySizeMb(ram_str);
    const ram_pages = (ram_mb * KB_PER_MB) / PAGE_SIZE_KB;
    _ = client.setQuota(child_cid, ram_pages, vcpus, 0, 0) catch {};

    const base_gpa: usize = switch (arch_num) {
        @intFromEnum(api.TargetArch.x86_64) => 0,
        @intFromEnum(api.TargetArch.aarch64) => 0x40000000,
        else => 0xe0000000,
    };
    _ = loadElfViaForeignMapping(client, child_cid, elf_data, dtb_data, base_gpa, ram_mb * 1024 * 1024, vcpus) catch |err| {
        printApiError("Load guest ELF", err);
        _ = client.terminate(child_cid, 1) catch {};
        return;
    };

    if (domain_name) |dname| {
        const m_file = manifest_path orelse "/etc/diosix/system.toml";
        if (readBinaryFile(m_file, MAX_MANIFEST_SIZE)) |m_content| {
            defer unmapBinaryFile(m_content);
            if (manifest.parseSystemManifest(allocator, m_content)) |sys_m_val| {
                var sys_m = sys_m_val;
                defer sys_m.deinit();
                if (manifest.pruneSystemManifest(allocator, &sys_m, dname, child_cid, CID_SELF, null)) |child_m_val| {
                    var child_m = child_m_val;
                    defer child_m.deinit();
                    if (manifest.serializeChildManifest(allocator, &child_m)) |child_toml| {
                        defer allocator.free(child_toml);
                        _ = client.setManifest(child_cid, child_toml) catch {};
                    } else |_| {}
                } else |_| {}
            } else |_| {}
        } else |_| {}
    }

    var final_disk_buf: [MAX_PATH_LEN]u8 = undefined;
    var final_disk: []const u8 = "";
    if (disk_str) |d| {
        if (std.mem.startsWith(u8, d, "/")) {
            final_disk = d;
        } else if (d.len > 0 and std.ascii.isDigit(d[0])) {
            const d_mb = parseMemorySizeMb(d);
            if (provisionVirtualDisk(vm_name.?, d_mb, &final_disk_buf)) |p| {
                final_disk = p;
            } else {
                final_disk = std.fmt.bufPrint(&final_disk_buf, "/var/lib/diosix/disks/{s}.img", .{vm_name.?}) catch "/var/lib/diosix/disks/disk.img";
            }
        } else {
            const disk_base = if (std.mem.endsWith(u8, d, ".img") or std.mem.endsWith(u8, d, ".raw"))
                d[0 .. d.len - 4]
            else
                d;
            var test_z: [MAX_PATH_LEN]u8 = undefined;
            const test_path = std.fmt.bufPrint(&test_z, "/var/lib/diosix/disks/{s}.img", .{disk_base}) catch "/var/lib/diosix/disks/disk.img";
            var z_check: [MAX_PATH_LEN]u8 = undefined;
            @memcpy(z_check[0..test_path.len], test_path);
            z_check[test_path.len] = 0;
            const check_fd = linux.open(@ptrCast(z_check[0..test_path.len :0]), .{ .ACCMODE = .RDONLY }, 0);
            const check_signed: isize = @bitCast(check_fd);
            if (check_signed >= 0) {
                _ = linux.close(@intCast(check_signed));
                final_disk = std.fmt.bufPrint(&final_disk_buf, "{s}", .{test_path}) catch test_path;
            } else {
                if (provisionVirtualDisk(disk_base, 1024, &final_disk_buf)) |p| {
                    final_disk = p;
                } else {
                    final_disk = std.fmt.bufPrint(&final_disk_buf, "{s}", .{test_path}) catch test_path;
                }
            }
        }
    }

    var final_cdrom_buf: [MAX_PATH_LEN]u8 = undefined;
    var final_cdrom: []const u8 = "";
    if (cdrom_str) |c| {
        if (std.mem.startsWith(u8, c, "/")) {
            final_cdrom = c;
        } else if (std.mem.endsWith(u8, c, ".iso") or std.mem.endsWith(u8, c, ".raw")) {
            final_cdrom = std.fmt.bufPrint(&final_cdrom_buf, "/var/lib/diosix/iso/{s}", .{c}) catch c;
        } else {
            final_cdrom = std.fmt.bufPrint(&final_cdrom_buf, "/var/lib/diosix/iso/{s}.iso", .{c}) catch c;
        }
    }

    var final_ip_buf: [64]u8 = undefined;
    const final_ip: []const u8 = if (ip_str.len > 0)
        ip_str
    else
        std.fmt.bufPrint(&final_ip_buf, "10.0.3.{d}", .{child_cid}) catch "10.0.3.2";

    var final_ram_buf: [32]u8 = undefined;
    const final_ram_str = std.fmt.bufPrint(&final_ram_buf, "{d} MB", .{ram_mb}) catch "256 MB";

    saveGuestRegistry(child_cid, vm_name.?, vcpus, final_ram_str, final_disk, final_cdrom, final_ip, if (trusted) "trusted" else "untrusted", "running");

    var msg_buf: [384]u8 = undefined;
    if (final_disk.len > 0 and final_cdrom.len > 0) {
        const out_msg = std.fmt.bufPrint(&msg_buf, "✓ Child VM '{s}' (CID {d}, {d} vCPUs, {s} RAM, Disk: {s}, CD-ROM: {s}, IP: {s}) started in background.\n", .{
            vm_name.?,
            child_cid,
            vcpus,
            final_ram_str,
            final_disk,
            final_cdrom,
            final_ip,
        }) catch return;
        printStr(out_msg);
    } else if (final_disk.len > 0) {
        const out_msg = std.fmt.bufPrint(&msg_buf, "✓ Child VM '{s}' (CID {d}, {d} vCPUs, {s} RAM, Disk: {s}, IP: {s}) started in background.\n", .{
            vm_name.?,
            child_cid,
            vcpus,
            final_ram_str,
            final_disk,
            final_ip,
        }) catch return;
        printStr(out_msg);
    } else if (final_cdrom.len > 0) {
        const out_msg = std.fmt.bufPrint(&msg_buf, "✓ Child VM '{s}' (CID {d}, {d} vCPUs, {s} RAM, CD-ROM: {s}, IP: {s}) started in background.\n", .{
            vm_name.?,
            child_cid,
            vcpus,
            final_ram_str,
            final_cdrom,
            final_ip,
        }) catch return;
        printStr(out_msg);
    } else {
        const out_msg = std.fmt.bufPrint(&msg_buf, "✓ Child VM '{s}' (CID {d}, {d} vCPUs, {s} RAM, IP: {s}) started in background.\n", .{
            vm_name.?,
            child_cid,
            vcpus,
            final_ram_str,
            final_ip,
        }) catch return;
        printStr(out_msg);
    }
}

fn cmdList(client: *api.DiosixClient) !void {
    const info_res = client.getInfo(1) catch null;
    const is_root = if (info_res) |info| info.is_root != 0 else true;
    const is_trusted = if (info_res) |info| info.is_trusted != 0 else true;
    const default_self_vcpus: usize = if (is_root) 4 else 1;
    const self_vcpus = if (info_res) |info| (if (info.vcpus > 0) info.vcpus else default_self_vcpus) else 4;
    const default_ram: usize = if (is_root) 512 else 256;
    const ram_mb = if (info_res) |info| (if (info.self_ram_pages > 0) ((info.self_ram_pages * PAGE_SIZE_KB) / KB_PER_MB) else default_ram) else default_ram;
    const child_count = if (info_res) |info| info.child_count else 0;

    printStr("CID   Name             vCPUs   RAM       Status    Trust       IP / Endpoint\n");

    var self_ram_buf: [32]u8 = undefined;
    const self_ram_str = std.fmt.bufPrint(&self_ram_buf, "{d} MB", .{if (ram_mb > 0) ram_mb else default_ram}) catch "256 MB";
    const self_name = if (is_root) "root (self)" else "self";
    printGuestLine(1, self_name, self_vcpus, self_ram_str, "running", if (is_trusted) "trusted" else "untrusted", "local");

    var guest_count: usize = 0;
    if (readBinaryFile("/var/run/diosix/guests.toml", MAX_MANIFEST_SIZE)) |content| {
        defer unmapBinaryFile(content);
        var lexer = manifest.ManifestLexer.init(content);

        var cur_cid: usize = 0;
        var cur_name: []const u8 = "";
        var cur_vcpus: usize = 1;
        var cur_ram: []const u8 = "256 MB";
        var cur_disk: []const u8 = "";
        var cur_ip: []const u8 = "";
        var cur_trust: []const u8 = "untrusted";
        var cur_status: []const u8 = "running";

        while (true) {
            const tok = lexer.next();
            if (tok.tag == .eof) {
                if (cur_cid >= CID_FIRST_CHILD) {
                    const c_mb = parseMemorySizeMb(cur_ram);
                    var child_ram_buf: [32]u8 = undefined;
                    const child_ram_str = std.fmt.bufPrint(&child_ram_buf, "{d} MB", .{c_mb}) catch cur_ram;
                    printGuestLine(cur_cid, cur_name, cur_vcpus, child_ram_str, cur_status, cur_trust, cur_ip);
                    guest_count += 1;
                }
                break;
            }
            if (tok.tag == .bracket_open) {
                if (cur_cid >= CID_FIRST_CHILD) {
                    const c_mb = parseMemorySizeMb(cur_ram);
                    var child_ram_buf: [32]u8 = undefined;
                    const child_ram_str = std.fmt.bufPrint(&child_ram_buf, "{d} MB", .{c_mb}) catch cur_ram;
                    printGuestLine(cur_cid, cur_name, cur_vcpus, child_ram_str, cur_status, cur_trust, cur_ip);
                    guest_count += 1;
                    cur_cid = 0;
                    cur_name = "";
                    cur_vcpus = 1;
                    cur_ram = "256 MB";
                    cur_disk = "";
                    cur_ip = "";
                    cur_trust = "untrusted";
                    cur_status = "running";
                }
                continue;
            }
            if (tok.tag == .ident or tok.tag == .string) {
                const key = tok.val;
                const eq = lexer.next();
                if (eq.tag != .equals) continue;
                const val = lexer.next();
                if (std.mem.eql(u8, key, "cid")) {
                    cur_cid = std.fmt.parseInt(usize, val.val, 10) catch 0;
                } else if (std.mem.eql(u8, key, "name")) {
                    cur_name = val.val;
                } else if (std.mem.eql(u8, key, "vcpus")) {
                    cur_vcpus = std.fmt.parseInt(usize, val.val, 10) catch 1;
                } else if (std.mem.eql(u8, key, "ram")) {
                    cur_ram = val.val;
                } else if (std.mem.eql(u8, key, "disk")) {
                    cur_disk = val.val;
                } else if (std.mem.eql(u8, key, "ip")) {
                    cur_ip = val.val;
                } else if (std.mem.eql(u8, key, "trust")) {
                    cur_trust = val.val;
                } else if (std.mem.eql(u8, key, "status")) {
                    cur_status = val.val;
                }
            }
        }
    } else |_| {}

    if (guest_count == 0 and child_count == 0) {
        printStr("\nNo child VMs running.\n");
    }
}

fn trimWhitespace(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and (s[start] == ' ' or s[start] == '\t' or s[start] == '\r' or s[start] == '\n')) : (start += 1) {}
    var end: usize = s.len;
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t' or s[end - 1] == '\r' or s[end - 1] == '\n')) : (end -= 1) {}
    return s[start..end];
}

fn cmdSsh(client: *api.DiosixClient, args: []const [*:0]const u8, exe_name: []const u8) !void {
    _ = client;
    if (args.len == 0) {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf,
            \\Usage: {s} ssh [user@]<name|cid> [-- [command...]]
            \\       {s} ssh [--user <username>] <name|cid> [-- [command...]]
            \\
        , .{ exe_name, exe_name }) catch return;
        printStr(msg);
        return;
    }

    var target_arg: []const u8 = "";
    var username: []const u8 = "root";
    var remote_cmd: ?[]const u8 = null;

    var cmd_str_buf: [512]u8 = undefined;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const span = std.mem.span(args[i]);
        if (std.mem.eql(u8, span, "--user") or std.mem.eql(u8, span, "-u")) {
            if (i + 1 >= args.len) {
                printStr("Error: Option '--user' requires a username.\n");
                return;
            }
            i += 1;
            username = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, span, "--")) {
            if (i + 1 < args.len) {
                var buf_len: usize = 0;
                for (args[i + 1 ..]) |arg| {
                    const s = std.mem.span(arg);
                    if (buf_len > 0 and buf_len < cmd_str_buf.len) {
                        cmd_str_buf[buf_len] = ' ';
                        buf_len += 1;
                    }
                    const copy_len = @min(s.len, cmd_str_buf.len - buf_len);
                    @memcpy(cmd_str_buf[buf_len .. buf_len + copy_len], s[0..copy_len]);
                    buf_len += copy_len;
                }
                remote_cmd = cmd_str_buf[0..buf_len];
            }
            break;
        } else if (target_arg.len == 0 and !std.mem.startsWith(u8, span, "-")) {
            target_arg = span;
        } else if (target_arg.len > 0 and remote_cmd == null and !std.mem.startsWith(u8, span, "-")) {
            var buf_len: usize = 0;
            for (args[i..]) |arg| {
                const s = std.mem.span(arg);
                if (buf_len > 0 and buf_len < cmd_str_buf.len) {
                    cmd_str_buf[buf_len] = ' ';
                    buf_len += 1;
                }
                const copy_len = @min(s.len, cmd_str_buf.len - buf_len);
                @memcpy(cmd_str_buf[buf_len .. buf_len + copy_len], s[0..copy_len]);
                buf_len += copy_len;
            }
            remote_cmd = cmd_str_buf[0..buf_len];
            break;
        } else if (std.mem.startsWith(u8, span, "-")) {
            var err_buf: [128]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "Error: Unknown option '{s}'. Usage: {s} ssh [user@]<name|cid> [-- [cmd...]]\n", .{ span, exe_name }) catch "Error: Unknown option.\n";
            printStr(err_msg);
            return;
        }
    }

    if (target_arg.len == 0) {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Error: No target VM specified. Usage: {s} ssh [user@]<name|cid>\n", .{exe_name}) catch return;
        printStr(msg);
        return;
    }

    var target_str: []const u8 = target_arg;
    if (std.mem.indexOfScalar(u8, target_arg, '@')) |at_idx| {
        username = target_arg[0..at_idx];
        target_str = target_arg[at_idx + 1 ..];
    }

    var resolved_cid: usize = parseCid(target_str) catch 0;
    var resolved_name: []const u8 = target_str;
    var resolved_ip: []const u8 = "";

    var ip_storage: [64]u8 = undefined;
    var name_storage: [64]u8 = undefined;

    const is_self = std.mem.eql(u8, target_str, "root") or std.mem.eql(u8, target_str, "self") or resolved_cid == 1;
    if (is_self) {
        resolved_cid = 1;
        resolved_name = "root";
        resolved_ip = "127.0.0.1";
    }

    if (readBinaryFile("/var/run/diosix/guests.toml", MAX_MANIFEST_SIZE)) |content| {
        defer unmapBinaryFile(content);
        var lexer = manifest.ManifestLexer.init(content);

        var cur_cid: usize = 0;
        var cur_name: []const u8 = "";
        var cur_ip: []const u8 = "";

        while (true) {
            const tok = lexer.next();
            if (tok.tag == .eof) {
                if (matchTarget(target_str, resolved_cid, cur_cid, cur_name)) {
                    resolved_cid = cur_cid;
                    resolved_name = copyStr(&name_storage, cur_name);
                    resolved_ip = copyStr(&ip_storage, cur_ip);
                }
                break;
            }
            if (tok.tag == .bracket_open) {
                if (matchTarget(target_str, resolved_cid, cur_cid, cur_name)) {
                    resolved_cid = cur_cid;
                    resolved_name = copyStr(&name_storage, cur_name);
                    resolved_ip = copyStr(&ip_storage, cur_ip);
                    break;
                }
                cur_cid = 0;
                cur_name = "";
                cur_ip = "";
                continue;
            }
            if (tok.tag == .ident or tok.tag == .string) {
                const key = tok.val;
                const eq = lexer.next();
                if (eq.tag != .equals) continue;
                const val = lexer.next();
                if (std.mem.eql(u8, key, "cid")) {
                    cur_cid = std.fmt.parseInt(usize, val.val, 10) catch 0;
                } else if (std.mem.eql(u8, key, "name")) {
                    cur_name = val.val;
                } else if (std.mem.eql(u8, key, "ip")) {
                    cur_ip = val.val;
                }
            }
        }
    } else |_| {}

    if (resolved_ip.len == 0) {
        if (readBinaryFile("/etc/diosix/system.toml", MAX_MANIFEST_SIZE)) |content| {
            defer unmapBinaryFile(content);
            const allocator = std.heap.page_allocator;
            if (manifest.parseSystemManifest(allocator, content)) |sys_m_val| {
                var sys_m = sys_m_val;
                defer sys_m.deinit();
                if (sys_m.domains.get(target_str)) |dom| {
                    if (dom.ip.len > 0) resolved_ip = copyStr(&ip_storage, dom.ip);
                    if (dom.name.len > 0) resolved_name = copyStr(&name_storage, dom.name);
                }
            } else |_| {}
        } else |_| {}
    }

    if (resolved_ip.len == 0) {
        if (resolved_cid >= CID_FIRST_CHILD) {
            resolved_ip = std.fmt.bufPrint(&ip_storage, "10.0.3.{d}", .{resolved_cid}) catch "10.0.3.2";
        } else if (is_self) {
            resolved_ip = "127.0.0.1";
        } else {
            var err_buf: [128]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "Error: Guest '{s}' not found. Use '{s} list' to view running guests.\n", .{ target_str, exe_name }) catch "Error: Guest not found.\n";
            printStr(err_msg);
            return;
        }
    }

    const key_file = findPrivateKey();

    if (remote_cmd) |rc| {
        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Connecting to guest '{s}' ({s}) as '{s}': {s}\n", .{ resolved_name, resolved_ip, username, rc }) catch return;
        printStr(msg);
    } else {
        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Connecting to guest '{s}' ({s}) as '{s}' via SSH...\n", .{ resolved_name, resolved_ip, username }) catch return;
        printStr(msg);
    }

    try execSsh(key_file, username, resolved_ip, remote_cmd);
}

fn cmdStop(client: *api.DiosixClient, args: []const [*:0]const u8, exe_name: []const u8) !bool {
    if (args.len == 0) {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Usage: {s} stop <name|cid|self>\n", .{exe_name}) catch return false;
        printStr(msg);
        return false;
    }
    const target_str = std.mem.span(args[0]);
    if (std.mem.eql(u8, target_str, "parent") or std.mem.eql(u8, target_str, "0")) {
        printStr("Error: Cannot stop parent VM (CID 0).\n");
        return false;
    }
    if (std.mem.eql(u8, target_str, "self")) {
        if (client.getInfo(1)) |info| {
            if (info.is_root != 0) {
                var buf: [160]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Root VM cannot be stopped directly. Use '{s} host poweroff' or '{s} host reboot'.\n", .{ exe_name, exe_name }) catch return false;
                printStr(msg);
                return false;
            }
        } else |_| {}
        client.terminate(CID_SELF, 0) catch |err| {
            printApiError("Stop self", err);
            return false;
        };
        printStr("VM self-terminated.\n");
        return true;
    }

    var target_cid = parseCid(target_str) catch 0;
    var target_name: []const u8 = target_str;

    var name_storage: [64]u8 = undefined;

    if (readBinaryFile("/var/run/diosix/guests.toml", MAX_MANIFEST_SIZE)) |content| {
        defer unmapBinaryFile(content);
        var lexer = manifest.ManifestLexer.init(content);

        var cur_cid: usize = 0;
        var cur_name: []const u8 = "";

        while (true) {
            const tok = lexer.next();
            if (tok.tag == .eof) {
                if (matchTarget(target_str, target_cid, cur_cid, cur_name)) {
                    target_cid = cur_cid;
                    target_name = copyStr(&name_storage, cur_name);
                }
                break;
            }
            if (tok.tag == .bracket_open) {
                if (matchTarget(target_str, target_cid, cur_cid, cur_name)) {
                    target_cid = cur_cid;
                    target_name = copyStr(&name_storage, cur_name);
                    break;
                }
                cur_cid = 0;
                cur_name = "";
                continue;
            }
            if (tok.tag == .ident or tok.tag == .string) {
                const key = tok.val;
                const eq = lexer.next();
                if (eq.tag != .equals) continue;
                const val = lexer.next();
                if (std.mem.eql(u8, key, "cid")) {
                    cur_cid = std.fmt.parseInt(usize, val.val, 10) catch 0;
                } else if (std.mem.eql(u8, key, "name")) {
                    cur_name = val.val;
                }
            }
        }
    } else |_| {}

    if (target_cid < CID_FIRST_CHILD) {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Error: Unknown or invalid child VM '{s}'. Use '{s} list' to inspect active VMs.\n", .{ target_str, exe_name }) catch return false;
        printStr(msg);
        return false;
    }

    client.terminate(target_cid, 0) catch |err| {
        printApiError("Stop VM", err);
        return false;
    };
    removeGuestFromRegistry(target_cid);

    var msg_buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "✓ Child VM '{s}' (CID {d}) terminated.\n", .{ target_name, target_cid }) catch return true;
    printStr(msg);
    return true;
}

fn cmdRestart(client: *api.DiosixClient, args: []const [*:0]const u8, exe_name: []const u8) !void {
    if (args.len == 0) {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Usage: {s} restart <name|cid>\n", .{exe_name}) catch return;
        printStr(msg);
        return;
    }
    const target_str = std.mem.span(args[0]);
    if (std.mem.eql(u8, target_str, "parent") or std.mem.eql(u8, target_str, "0")) {
        printStr("Error: Cannot restart parent VM (CID 0).\n");
        return;
    }
    const stopped = try cmdStop(client, args, exe_name);
    if (!stopped) return;
    printStr("Restarting guest VM...\n");
    const run_args = [_][*:0]const u8{
        @ptrCast(target_str.ptr),
    };
    try cmdRun(client, &run_args, exe_name);
}

// -----------------------------------------------------------------------------
// Unit Tests
// -----------------------------------------------------------------------------
const testing = std.testing;

test "parseCid resolution" {
    try testing.expectEqual(CID_SELF, try parseCid("self"));
    try testing.expectEqual(CID_PARENT, try parseCid("parent"));
    try testing.expectEqual(@as(usize, 2), try parseCid("2"));
    try testing.expectEqual(@as(usize, 42), try parseCid("42"));
    try testing.expectError(error.InvalidCharacter, parseCid("invalid"));
}

test "isArch target detection" {
    try testing.expect(isArch("riscv64"));
    try testing.expect(isArch("riscv32"));
    try testing.expect(isArch("aarch64"));
    try testing.expect(isArch("x86_64"));
    try testing.expect(!isArch("x86"));
    try testing.expect(!isArch("arm"));
    try testing.expect(!isArch("mips"));
    try testing.expect(!isArch("other"));
}

test "parseMemorySizeMb unit conversions" {
    try testing.expectEqual(@as(usize, 256), parseMemorySizeMb("256 MB"));
    try testing.expectEqual(@as(usize, 256), parseMemorySizeMb("256MB"));
    try testing.expectEqual(@as(usize, 256), parseMemorySizeMb("256M"));
    try testing.expectEqual(@as(usize, 2048), parseMemorySizeMb("2GiB"));
    try testing.expectEqual(@as(usize, 2048), parseMemorySizeMb("2GB"));
    try testing.expectEqual(@as(usize, 2048), parseMemorySizeMb("2G"));
    try testing.expectEqual(@as(usize, 1), parseMemorySizeMb("1024KB"));
    try testing.expectEqual(@as(usize, 1), parseMemorySizeMb("1024K"));
    try testing.expectEqual(@as(usize, 512), parseMemorySizeMb("512"));
}

test "readBinaryFile error handling" {
    try testing.expectError(error.FileNotFound, readBinaryFile("/nonexistent/file/path/here.bin", 4096));

    // Valid file reading test
    const content = try readBinaryFile("VERSION", 1024);
    defer unmapBinaryFile(content);
    try testing.expect(content.len > 0);
}

test "guest registry serialization and query parsing" {
    const test_registry =
        \\[[guests]]
        \\cid = 2
        \\name = "user"
        \\vcpus = 2
        \\ram = "256 MB"
        \\ip = "10.0.3.2"
        \\trust = "untrusted"
        \\status = "running"
        \\
        \\[[guests]]
        \\cid = 3
        \\name = "sys-domain"
        \\vcpus = 4
        \\ram = "2GiB"
        \\ip = "10.0.3.3"
        \\trust = "trusted"
        \\status = "running"
        \\
    ;

    var lexer = manifest.ManifestLexer.init(test_registry);
    var guest_count: usize = 0;
    var found_user = false;
    var found_sys = false;

    var cur_cid: usize = 0;
    var cur_name: []const u8 = "";
    var cur_ip: []const u8 = "";

    while (true) {
        const tok = lexer.next();
        if (tok.tag == .eof) {
            if (cur_cid >= CID_FIRST_CHILD) {
                guest_count += 1;
                if (std.mem.eql(u8, cur_name, "user")) found_user = true;
                if (std.mem.eql(u8, cur_name, "sys-domain")) found_sys = true;
            }
            break;
        }
        if (tok.tag == .bracket_open) {
            if (cur_cid >= CID_FIRST_CHILD) {
                guest_count += 1;
                if (std.mem.eql(u8, cur_name, "user")) found_user = true;
                if (std.mem.eql(u8, cur_name, "sys-domain")) found_sys = true;
                cur_cid = 0;
                cur_name = "";
                cur_ip = "";
            }
            continue;
        }
        if (tok.tag == .ident or tok.tag == .string) {
            const key = tok.val;
            const eq = lexer.next();
            if (eq.tag != .equals) continue;
            const val = lexer.next();
            if (std.mem.eql(u8, key, "cid")) {
                cur_cid = try std.fmt.parseInt(usize, val.val, 10);
            } else if (std.mem.eql(u8, key, "name")) {
                cur_name = val.val;
            } else if (std.mem.eql(u8, key, "ip")) {
                cur_ip = val.val;
            }
        }
    }

    try testing.expectEqual(@as(usize, 2), guest_count);
    try testing.expect(found_user);
    try testing.expect(found_sys);
}

test "matchTarget resolution" {
    try testing.expect(matchTarget("user", 0, 2, "user"));
    try testing.expect(matchTarget("user", 2, 2, "user"));
    try testing.expect(matchTarget("2", 2, 2, "user"));
    try testing.expect(matchTarget("sys", 0, 3, "sys-domain"));
    try testing.expect(!matchTarget("other", 0, 2, "user"));
}

test "RAM string formatting normalization" {
    var buf1: [32]u8 = undefined;
    var buf2: [32]u8 = undefined;
    var buf3: [32]u8 = undefined;

    const s1 = std.fmt.bufPrint(&buf1, "{d} MB", .{parseMemorySizeMb("256M")}) catch "";
    const s2 = std.fmt.bufPrint(&buf2, "{d} MB", .{parseMemorySizeMb("512 MB")}) catch "";
    const s3 = std.fmt.bufPrint(&buf3, "{d} MB", .{parseMemorySizeMb("2GiB")}) catch "";

    try testing.expectEqualStrings("256 MB", s1);
    try testing.expectEqualStrings("512 MB", s2);
    try testing.expectEqualStrings("2048 MB", s3);
}

test "disk path and capacity resolution" {
    var path_buf: [MAX_PATH_LEN]u8 = undefined;
    const disk_name = "user-data";
    const full_path = std.fmt.bufPrint(&path_buf, "/var/lib/diosix/disks/{s}.img", .{disk_name}) catch "";
    try testing.expectEqualStrings("/var/lib/diosix/disks/user-data.img", full_path);

    const size_2g = parseMemorySizeMb("2G");
    try testing.expectEqual(@as(usize, 2048), size_2g);
    const size_512m = parseMemorySizeMb("512M");
    try testing.expectEqual(@as(usize, 512), size_512m);
}

test "snapshot path resolution" {
    var snap_buf: [MAX_PATH_LEN]u8 = undefined;
    const snap_path = std.fmt.bufPrint(&snap_buf, "/var/lib/diosix/snapshots/{s}_{s}.snap", .{ "leenix", "checkpoint-1" }) catch "";
    try testing.expectEqualStrings("/var/lib/diosix/snapshots/leenix_checkpoint-1.snap", snap_path);
}

test "image and cdrom path resolution" {
    var iso_buf: [MAX_PATH_LEN]u8 = undefined;
    const iso_name = "debian-12-netinst";
    const full_iso_path = std.fmt.bufPrint(&iso_buf, "/var/lib/diosix/iso/{s}.iso", .{iso_name}) catch "";
    try testing.expectEqualStrings("/var/lib/diosix/iso/debian-12-netinst.iso", full_iso_path);

    var img_buf: [MAX_PATH_LEN]u8 = undefined;
    const img_name = "debian-installer";
    const full_img_path = std.fmt.bufPrint(&img_buf, "/var/lib/diosix/images/{s}.elf", .{img_name}) catch "";
    try testing.expectEqualStrings("/var/lib/diosix/images/debian-installer.elf", full_img_path);
}



