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
pub const MAX_ELF_FILE_SIZE: usize = 64 * 1024 * 1024;
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

pub fn main(init: std.process.Init.Minimal) !void {
    const argv = init.args.vector;

    if (argv.len < 2) {
        printUsage();
        return;
    }

    var client = api.DiosixClient.init();
    defer client.deinit();

    const command = std.mem.span(argv[1]);

    if (std.mem.eql(u8, command, "info")) {
        var host_mode = false;
        for (argv[2..]) |arg| {
            const span = std.mem.span(arg);
            if (std.mem.eql(u8, span, "--host") or std.mem.eql(u8, span, "-h")) {
                host_mode = true;
            }
        }
        if (host_mode) {
            try cmdHostInfo(&client);
        } else {
            try cmdInfo(&client);
        }
    } else if (std.mem.eql(u8, command, "fork")) {
        var spawn_mode = false;
        var spawn_idx: usize = 0;
        var untrusted = false;
        for (argv[2..], 2..) |arg, i| {
            const span = std.mem.span(arg);
            if (std.mem.eql(u8, span, "--spawn")) {
                spawn_mode = true;
                spawn_idx = i;
            } else if (std.mem.eql(u8, span, "--untrusted") or std.mem.eql(u8, span, "--drop-trust")) {
                untrusted = true;
            }
        }
        if (spawn_mode) {
            if (argv.len <= spawn_idx + 1) {
                printStr("Usage: dsx fork --spawn <elf_path> [dtb_path] [arch] [--trusted]\n");
                return;
            }
            const elf_path = std.mem.span(argv[spawn_idx + 1]);
            var dtb_path: ?[]const u8 = null;
            var arch_str: []const u8 = "riscv64";
            var flags: usize = 0;
            for (argv[spawn_idx + 2 ..]) |arg| {
                const span = std.mem.span(arg);
                if (std.mem.eql(u8, span, "--trusted")) {
                    flags |= api.SpawnFlags.TRUSTED;
                } else if (isArch(span)) {
                    arch_str = span;
                } else if (dtb_path == null) {
                    dtb_path = span;
                }
            }
            try cmdSpawn(&client, 0, elf_path, dtb_path, arch_str, flags);
        } else {
            const fork_flags: usize = if (untrusted) api.ForkFlags.UNTRUSTED else 0;
            try cmdFork(&client, fork_flags);
        }
    } else if (std.mem.eql(u8, command, "drop-trust")) {
        try cmdDropTrust(&client);
    } else if (std.mem.eql(u8, command, "spawn")) {
        if (argv.len < 3) {
            printStr("Usage: dsx spawn <elf_path> [dtb_path] [arch] [--trusted]\n");
            printStr("       dsx spawn <cid> <elf_path> [dtb_path] [arch] [--trusted]\n");
            return;
        }
        var child_id: usize = 0;
        var elf_path: ?[]const u8 = null;
        var dtb_path: ?[]const u8 = null;
        var arch_str: []const u8 = "riscv64";
        var flags: usize = 0;

        var non_flag_args: [MAX_POSITIONAL_ARGS][]const u8 = undefined;
        var non_flag_count: usize = 0;

        for (argv[2..]) |arg| {
            const span = std.mem.span(arg);
            if (std.mem.eql(u8, span, "--trusted")) {
                flags |= api.SpawnFlags.TRUSTED;
            } else if (std.mem.eql(u8, span, "--untrusted")) {
                flags &= ~api.SpawnFlags.TRUSTED;
            } else if (non_flag_count < non_flag_args.len) {
                non_flag_args[non_flag_count] = span;
                non_flag_count += 1;
            }
        }

        if (non_flag_count == 0) {
            printStr("Usage: dsx spawn <elf_path> [dtb_path] [arch] [--trusted]\n");
            return;
        }

        if (parseCid(non_flag_args[0])) |cid| {
            if (cid >= CID_FIRST_CHILD and non_flag_count >= 2) {
                child_id = cid;
                elf_path = non_flag_args[1];
                if (non_flag_count > 2) {
                    if (isArch(non_flag_args[2])) {
                        arch_str = non_flag_args[2];
                    } else {
                        dtb_path = non_flag_args[2];
                        if (non_flag_count > 3) arch_str = non_flag_args[3];
                    }
                }
            } else {
                child_id = 0;
                elf_path = non_flag_args[0];
                if (non_flag_count > 1) {
                    if (isArch(non_flag_args[1])) {
                        arch_str = non_flag_args[1];
                    } else {
                        dtb_path = non_flag_args[1];
                        if (non_flag_count > 2) arch_str = non_flag_args[2];
                    }
                }
            }
        } else |_| {
            child_id = 0;
            elf_path = non_flag_args[0];
            if (non_flag_count > 1) {
                if (isArch(non_flag_args[1])) {
                    arch_str = non_flag_args[1];
                } else {
                    dtb_path = non_flag_args[1];
                    if (non_flag_count > 2) arch_str = non_flag_args[2];
                }
            }
        }

        if (elf_path) |ep| {
            try cmdSpawn(&client, child_id, ep, dtb_path, arch_str, flags);
        } else {
            printStr("Missing ELF file path.\n");
        }
    } else if (std.mem.eql(u8, command, "quota")) {
        if (argv.len < 3) {
            printStr("Usage: dsx quota <cid|self> [--ram <MB>] [--vcpus <N>] [--depth <N>] [--descendants <N>]\n");
            return;
        }
        const target_cid = try parseCid(std.mem.span(argv[2]));
        try cmdQuota(&client, target_cid, argv);
    } else if (std.mem.eql(u8, command, "send")) {
        if (argv.len < 4) {
            printStr("Usage: dsx send <cid|parent> <message>\n");
            return;
        }
        const target_cid = try parseCid(std.mem.span(argv[2]));
        const message = std.mem.span(argv[3]);
        try cmdSend(&client, target_cid, message);
    } else if (std.mem.eql(u8, command, "recv")) {
        var sender_cid: usize = 0;
        var nohang: bool = false;
        for (argv[2..]) |arg| {
            const span = std.mem.span(arg);
            if (std.mem.eql(u8, span, "--nohang") or std.mem.eql(u8, span, "-n")) {
                nohang = true;
            } else if (parseCid(span)) |cid| {
                sender_cid = cid;
            } else |_| {}
        }
        try cmdRecv(&client, sender_cid, nohang);
    } else if (std.mem.eql(u8, command, "wait")) {
        var target_cid: usize = 0;
        var nohang: bool = false;
        for (argv[2..]) |arg| {
            const span = std.mem.span(arg);
            if (std.mem.eql(u8, span, "--nohang") or std.mem.eql(u8, span, "-n")) {
                nohang = true;
            } else if (parseCid(span)) |cid| {
                target_cid = cid;
            } else |_| {}
        }
        try cmdWait(&client, target_cid, nohang);
    } else if (std.mem.eql(u8, command, "terminate")) {
        const target_id = if (argv.len > 2) try parseCid(std.mem.span(argv[2])) else CID_SELF;
        const exit_code = if (argv.len > 3) try std.fmt.parseInt(usize, std.mem.span(argv[3]), 10) else 0;
        try cmdTerminate(&client, target_id, exit_code);
    } else if (std.mem.eql(u8, command, "exit")) {
        const exit_code = if (argv.len > 2) try std.fmt.parseInt(usize, std.mem.span(argv[2]), 10) else 0;
        try cmdExit(&client, exit_code);
    } else if (std.mem.eql(u8, command, "poweroff")) {
        try cmdPoweroff(&client);
    } else if (std.mem.eql(u8, command, "reboot")) {
        try cmdReboot(&client);
    } else if (std.mem.eql(u8, command, "run") or std.mem.eql(u8, command, "create")) {
        try cmdRun(&client, argv[2..]);
    } else if (std.mem.eql(u8, command, "list") or std.mem.eql(u8, command, "ps") or std.mem.eql(u8, command, "ls")) {
        try cmdList(&client);
    } else if (std.mem.eql(u8, command, "login") or std.mem.eql(u8, command, "ssh") or std.mem.eql(u8, command, "console") or std.mem.eql(u8, command, "exec")) {
        try cmdLogin(&client, argv[2..]);
    } else if (std.mem.eql(u8, command, "stop") or std.mem.eql(u8, command, "kill")) {
        try cmdStop(&client, argv[2..]);
    } else if (std.mem.eql(u8, command, "manifest")) {
        try cmdManifest(&client, argv[2..]);
    } else if (std.mem.eql(u8, command, "resolve")) {
        if (argv.len < 3) {
            printStr("Usage: dsx resolve <service_alias> [--manifest <file.toml>]\n");
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
    } else if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help")) {
        printUsage();
    } else {
        printStr("Unknown command. Use 'dsx help' for available commands.\n");
    }
}

fn printUsage() void {
    const usage =
        \\dsx / diosix-ctl: Diosix hypervisor guest management tool
        \\
        \\Usage:
        \\  dsx info [--host]                  Display current VM state (or host hypervisor info)
        \\  dsx run <elf> [options]            Launch child VM in background with private SSH networking
        \\      [--name <name>]                Assign human-friendly VM name (e.g. 'user')
        \\      [--vcpus <N>]                  Allocate virtual CPUs (default: 1)
        \\      [--ram <size>]                 Allocate RAM limit (e.g. '256M', '2GiB')
        \\      [--ip <addr>]                  Assign private IP address (default: '10.0.3.<cid>')
        \\      [--manifest <file.toml>]       Stage attenuated domain manifest for child
        \\      [--domain <name>]              Extract domain configuration from system manifest
        \\      [--trusted]                    Grant hardware trust (default: untrusted)
        \\  dsx list / dsx ps                  List all active virtual machines and their endpoints
        \\  dsx login <name|cid> [-- [cmd]]    Log into child VM securely via private SSH (or run cmd)
        \\  dsx ssh <name|cid> [-- [cmd]]      Alias for dsx login
        \\  dsx stop <name|cid>                Terminate and stop running child VM
        \\  dsx manifest <subcmd> [options]    Manage hierarchical system & VM manifests
        \\      show [--file <path>] [--hv]    Display active or file manifest
        \\      validate <file.toml>           Validate system or child manifest syntax
        \\      prune <sys.toml> --domain <d>  Attenuate system manifest for a child VM domain
        \\      set <cid> <file.toml>          Stage attenuated manifest in hypervisor for child
        \\  dsx resolve <service_alias>        Resolve service alias or endpoint in current manifest
        \\  dsx spawn <elf> [opts] [--trusted] Create and boot a child VM directly from image
        \\  dsx fork [--untrusted]             Fork current VM to clone state (returns CID >= 2)
        \\  dsx fork --spawn <elf> [options]   Alias to create and boot a new child VM
        \\  dsx quota <cid|self> [options]     Set or lower VM resource quotas (--ram, --vcpus, --descendants)
        \\  dsx send <cid|parent> <msg>        Send an inter-VM IPC message to target VM
        \\  dsx recv [cid|parent] [--nohang]   Receive an inter-VM IPC message
        \\  dsx wait [cid|self] [--nohang]     Wait for child VM state changes / exit events
        \\  dsx terminate [cid|self] [code]    Terminate target VM (self or child CID)
        \\  dsx exit [code]                    Exit the current non-root VM (calls terminate self [code])
        \\  dsx poweroff                       Power off the host machine (Root VM only)
        \\  dsx reboot                         Reboot the host machine (Root VM only)
        \\  dsx drop-trust                     Irrevocably drop hardware trust privileges
        \\  dsx help                           Show this help message
        \\
    ;
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

fn cmdQuota(client: *api.DiosixClient, target_cid: usize, argv: []const [*:0]const u8) !void {
    var ram_pages: usize = 0;
    var vcpus: usize = 0;
    var depth: usize = 0;
    var descendants: usize = 0;

    var i: usize = 3;
    while (i < argv.len) : (i += 1) {
        const flag = std.mem.span(argv[i]);
        if (std.mem.eql(u8, flag, "--ram") and i + 1 < argv.len) {
            i += 1;
            const mb = try std.fmt.parseInt(usize, std.mem.span(argv[i]), 10);
            ram_pages = (mb * KB_PER_MB) / PAGE_SIZE_KB;
        } else if (std.mem.eql(u8, flag, "--vcpus") and i + 1 < argv.len) {
            i += 1;
            vcpus = try std.fmt.parseInt(usize, std.mem.span(argv[i]), 10);
        } else if (std.mem.eql(u8, flag, "--depth") and i + 1 < argv.len) {
            i += 1;
            depth = try std.fmt.parseInt(usize, std.mem.span(argv[i]), 10);
        } else if (std.mem.eql(u8, flag, "--descendants") and i + 1 < argv.len) {
            i += 1;
            descendants = try std.fmt.parseInt(usize, std.mem.span(argv[i]), 10);
        }
    }

    client.setQuota(target_cid, ram_pages, vcpus, depth, descendants) catch |err| {
        printApiError("Set quota", err);
        return;
    };
    printStr("Quotas updated successfully.\n");
}

fn cmdSend(client: *api.DiosixClient, target_cid: usize, message: []const u8) !void {
    client.sendIpc(target_cid, message) catch |err| {
        printApiError("Send IPC message", err);
        return;
    };
    printStr("Message sent successfully.\n");
}

fn cmdRecv(client: *api.DiosixClient, sender_cid: usize, nohang: bool) !void {
    var buffer: [MAX_IPC_BUF_LEN]u8 = undefined;
    if (!nohang) {
        _ = client.waitEvent(0, false) catch {};
    }
    const maybe_msg = client.recvIpc(sender_cid, &buffer) catch |err| {
        printApiError("Receive IPC message", err);
        return;
    };
    if (maybe_msg) |msg| {
        var header: [64]u8 = undefined;
        const hmsg = std.fmt.bufPrint(&header, "[IPC message from CID {d} ({d} bytes)]:\n", .{ msg.sender_cid, msg.data.len }) catch return;
        printStr(hmsg);
        printStr(msg.data);
        printStr("\n");
    } else {
        printStr("No messages received.\n");
    }
}

fn cmdWait(client: *api.DiosixClient, target_cid: usize, nohang: bool) !void {
    if (!nohang) {
        if (target_cid > 0) {
            var buf: [64]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Waiting for child VM (CID {d}) event...\n", .{target_cid}) catch return;
            printStr(msg);
        } else {
            printStr("Waiting for child VM events...\n");
        }
    }
    const maybe_event = client.waitEvent(target_cid, nohang) catch |err| {
        printApiError("Wait", err);
        return;
    };
    if (maybe_event) |ev| {
        var buf: [128]u8 = undefined;
        const type_str = switch (@as(api.EventType, @enumFromInt(ev.event_type))) {
            .child_terminated => "terminated",
            .child_stopped => "stopped",
            .child_spawned => "spawned",
            .ipc_message => "ipc_message",
            .none => "none",
        };
        const msg = std.fmt.bufPrint(&buf, "Child VM (CID {d}) {s} with exit code {d}.\n", .{ ev.cid, type_str, ev.exit_code }) catch return;
        printStr(msg);
    } else {
        printStr("No child events pending.\n");
    }
}

fn cmdTerminate(client: *api.DiosixClient, target_id: usize, exit_code: usize) !void {
    if (target_id == CID_SELF or target_id == CID_PARENT) {
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Terminating current VM (exit code {d})...\n", .{exit_code}) catch return;
        printStr(msg);
    } else {
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Terminating child VM {d} and all descendants...\n", .{target_id}) catch return;
        printStr(msg);
    }
    client.terminate(target_id, exit_code) catch |err| {
        printApiError("Terminate", err);
        return;
    };
    printStr("VM successfully terminated.\n");
}

fn cmdExit(client: *api.DiosixClient, exit_code: usize) !void {
    if (client.getInfo()) |info| {
        if (info.is_root != 0) {
            printStr("Root VM cannot use 'exit'. Use 'poweroff' or 'reboot' to stop the host.\n");
            return;
        }
    } else |err| {
        printApiError("Query VM info", err);
        return;
    }
    try cmdTerminate(client, CID_SELF, exit_code);
}

fn cmdPoweroff(client: *api.DiosixClient) !void {
    if (client.getInfo()) |info| {
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
    if (client.getInfo()) |info| {
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

fn cmdInfo(client: *api.DiosixClient) !void {
    const info = client.getInfo() catch |err| {
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
    const ram_mb = (info.used_ram_pages * PAGE_SIZE_KB) / KB_PER_MB;

    var buf: [512]u8 = undefined;
    const out = std.fmt.bufPrint(&buf,
        \\=== Diosix guest VM info ===
        \\Context ID     : {d}
        \\Parent CID     : {d}
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
        arch_name,
        is_root_str,
        is_trusted_str,
        ram_mb,
        info.used_ram_pages,
        info.used_vcpus,
        info.child_count,
    }) catch return;

    printStr(out);
}

fn cmdHostInfo(client: *api.DiosixClient) !void {
    const info = client.getHypervisorInfo() catch |err| {
        printApiError("Query host hypervisor info", err);
        return;
    };

    var buf: [512]u8 = undefined;
    const commit_str = std.mem.sliceTo(&info.build_commit, 0);
    const out = std.fmt.bufPrint(&buf,
        \\=== Diosix hypervisor information ===
        \\Diosix version  : {d}.{d} (Commit {s})
        \\ABI version     : {d}.{d}.{d}
        \\Host cores      : {d} physical hart(s)
        \\Host RAM        : {d} MB total / {d} MB free
        \\Timer frequency : {d} Hz
        \\Capabilities    :
        \\  [{c}] Hardware H-extension (nested virtualization)
        \\  [{c}] Stage-2 Sv39x4 paging
        \\  [{c}] Copy-on-write VM forking
        \\  [{c}] Cross-arch JIT dynamic recompilation
        \\  [{c}] Inter-VM fast IPC
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
        if ((info.features & api.HypervisorFeature.COW_FORK) != 0) @as(u8, 'x') else @as(u8, ' '),
        if ((info.features & api.HypervisorFeature.DYNAREC) != 0) @as(u8, 'x') else @as(u8, ' '),
        if ((info.features & api.HypervisorFeature.INTER_VM_IPC) != 0) @as(u8, 'x') else @as(u8, ' '),
    }) catch return;

    printStr(out);
}

fn isArch(str: []const u8) bool {
    return std.mem.eql(u8, str, "riscv64") or
        std.mem.eql(u8, str, "riscv32") or
        std.mem.eql(u8, str, "aarch64") or
        std.mem.eql(u8, str, "x86_64");
}

fn cmdFork(client: *api.DiosixClient, flags: usize) !void {
    const is_untrusted = (flags & api.ForkFlags.UNTRUSTED) != 0;
    if (is_untrusted) {
        printStr("Forking current VM (dropping hardware trust for child)...\n");
    } else {
        printStr("Forking current VM...\n");
    }
    const child_cid = client.fork(flags) catch |err| {
        printApiError("Fork", err);
        return;
    };
    if (child_cid == 0) {
        return;
    }
    saveGuestRegistry(child_cid, if (is_untrusted) "fork-untrusted" else "fork-trusted", 1, "512 MB", "", if (is_untrusted) "untrusted" else "trusted", "running");
    var buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Successfully forked child VM with CID: {d}\n", .{child_cid}) catch return;
    printStr(msg);
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

    const mmap_res = linux.mmap(null, max_size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
    const mmap_signed: isize = @bitCast(mmap_res);
    if (mmap_signed < 0) return error.OutOfMemory;
    const buf: [*]u8 = @ptrFromInt(mmap_res);

    var total_read: usize = 0;
    while (total_read < max_size) {
        const read_res = linux.read(fd, buf + total_read, max_size - total_read);
        const r_signed: isize = @bitCast(read_res);
        if (r_signed <= 0) break;
        total_read += @intCast(r_signed);
    }
    return buf[0..total_read];
}

fn cmdSpawn(client: *api.DiosixClient, child_id: usize, elf_path: []const u8, dtb_path: ?[]const u8, arch_str: []const u8, flags: usize) !void {
    const is_trusted_req = (flags & api.SpawnFlags.TRUSTED) != 0;
    if (child_id == 0) {
        if (is_trusted_req) {
            printStr("Creating clean trusted child VM and loading guest image...\n");
        } else {
            printStr("Creating clean sandboxed child VM and loading guest image...\n");
        }
    } else {
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Loading guest image into child VM {d}...\n", .{child_id}) catch return;
        printStr(msg);
    }

    const elf_data = readBinaryFile(elf_path, MAX_ELF_FILE_SIZE) catch |err| {
        if (err == error.FileNotFound) {
            printStr("Failed to open ELF file: file not found.\n");
        } else if (err == error.PathTooLong) {
            printStr("ELF file path exceeds maximum path length.\n");
        } else {
            printStr("Failed to read ELF file.\n");
        }
        return;
    };
    defer _ = linux.munmap(elf_data.ptr, MAX_ELF_FILE_SIZE);

    if (elf_data.len == 0) {
        printStr("ELF file is empty or unreadable.\n");
        return;
    }

    var dtb_data: []u8 = &[_]u8{};
    if (dtb_path) |dp| {
        dtb_data = readBinaryFile(dp, MAX_DTB_FILE_SIZE) catch |err| {
            if (err == error.FileNotFound) {
                printStr("Failed to open DTB file: file not found.\n");
            } else {
                printStr("Failed to read DTB file.\n");
            }
            return;
        };
    }
    defer if (dtb_data.len > 0) {
        _ = linux.munmap(dtb_data.ptr, MAX_DTB_FILE_SIZE);
    };

    var arch_num: usize = @intFromEnum(api.TargetArch.riscv64);
    if (std.mem.eql(u8, arch_str, "riscv32")) {
        arch_num = @intFromEnum(api.TargetArch.riscv32);
    } else if (std.mem.eql(u8, arch_str, "aarch64")) {
        arch_num = @intFromEnum(api.TargetArch.aarch64);
    } else if (std.mem.eql(u8, arch_str, "x86_64")) {
        arch_num = @intFromEnum(api.TargetArch.x86_64);
    }

    const spawned_cid = client.spawn(child_id, elf_data, dtb_data, arch_num, flags) catch |err| {
        printApiError("Spawn VM", err);
        return;
    };
    saveGuestRegistry(spawned_cid, "spawned", 1, "256 MB", "", if (is_trusted_req) "trusted" else "untrusted", "running");
    var buf2: [64]u8 = undefined;
    const msg2 = std.fmt.bufPrint(&buf2, "Child VM (CID {d}) successfully spawned and started.\n", .{spawned_cid}) catch return;
    printStr(msg2);
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

fn cmdManifest(client: *api.DiosixClient, args: []const [*:0]const u8) !void {
    if (args.len == 0) {
        printStr("Usage: dsx manifest <show|validate|prune|set> [options]\n");
        return;
    }
    const subcmd = std.mem.span(args[0]);
    const allocator = std.heap.page_allocator;

    if (std.mem.eql(u8, subcmd, "show")) {
        var file_path: ?[]const u8 = null;
        var use_hv: bool = false;
        var target_cid: usize = CID_SELF;

        for (args[1..], 1..) |arg, i| {
            const span = std.mem.span(arg);
            if (std.mem.eql(u8, span, "--file") or std.mem.eql(u8, span, "-f")) {
                if (args.len > i + 1) {
                    file_path = std.mem.span(args[i + 1]);
                }
            } else if (std.mem.eql(u8, span, "--hypervisor") or std.mem.eql(u8, span, "--hv")) {
                use_hv = true;
            } else if (std.mem.eql(u8, span, "--cid") or std.mem.eql(u8, span, "-c")) {
                if (args.len > i + 1) {
                    target_cid = parseCid(std.mem.span(args[i + 1])) catch CID_SELF;
                }
            }
        }

        if (file_path) |fp| {
            const content = readBinaryFile(fp, MAX_MANIFEST_SIZE) catch |err| {
                printStr("Failed to read manifest file: ");
                printStr(@errorName(err));
                printStr("\n");
                return;
            };
            defer _ = linux.munmap(content.ptr, MAX_MANIFEST_SIZE);
            printStr(content);
            if (content.len > 0 and content[content.len - 1] != '\n') {
                printStr("\n");
            }
        } else if (use_hv) {
            var m_buf: [MAX_MANIFEST_SIZE]u8 = undefined;
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
                defer _ = linux.munmap(content.ptr, MAX_MANIFEST_SIZE);
                printStr(content);
                if (content.len > 0 and content[content.len - 1] != '\n') printStr("\n");
            } else |_| {
                if (readBinaryFile("/etc/diosix/system.toml", MAX_MANIFEST_SIZE)) |content| {
                    defer _ = linux.munmap(content.ptr, MAX_MANIFEST_SIZE);
                    printStr(content);
                    if (content.len > 0 and content[content.len - 1] != '\n') printStr("\n");
                } else |_| {
                    var m_buf: [MAX_MANIFEST_SIZE]u8 = undefined;
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
            printStr("Usage: dsx manifest validate <path/to/manifest.toml>\n");
            return;
        }
        const file_path = std.mem.span(args[1]);
        const content = readBinaryFile(file_path, MAX_MANIFEST_SIZE) catch |err| {
            printStr("Failed to read manifest file: ");
            printStr(@errorName(err));
            printStr("\n");
            return;
        };
        defer _ = linux.munmap(content.ptr, MAX_MANIFEST_SIZE);

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
            printStr("Usage: dsx manifest prune <system.toml> --domain <name> [-o <out.toml>] [--cid <cid>]\n");
            return;
        }
        const sys_path = std.mem.span(args[1]);
        var domain_name: ?[]const u8 = null;
        var out_file: ?[]const u8 = null;
        var child_cid: usize = CID_FIRST_CHILD;
        var parent_cid: usize = CID_SELF;

        for (args[2..], 2..) |arg, i| {
            const span = std.mem.span(arg);
            if (std.mem.eql(u8, span, "--domain") or std.mem.eql(u8, span, "-d")) {
                if (args.len > i + 1) domain_name = std.mem.span(args[i + 1]);
            } else if (std.mem.eql(u8, span, "-o") or std.mem.eql(u8, span, "--out")) {
                if (args.len > i + 1) out_file = std.mem.span(args[i + 1]);
            } else if (std.mem.eql(u8, span, "--cid") or std.mem.eql(u8, span, "-c")) {
                if (args.len > i + 1) child_cid = parseCid(std.mem.span(args[i + 1])) catch CID_FIRST_CHILD;
            } else if (std.mem.eql(u8, span, "--parent") or std.mem.eql(u8, span, "-p")) {
                if (args.len > i + 1) parent_cid = parseCid(std.mem.span(args[i + 1])) catch CID_SELF;
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
        defer _ = linux.munmap(content.ptr, MAX_MANIFEST_SIZE);

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
            printStr("Usage: dsx manifest set <target_cid> <path/to/manifest.toml>\n");
            return;
        }
        const target_cid = parseCid(std.mem.span(args[1])) catch {
            printStr("Invalid target CID\n");
            return;
        };
        const file_path = std.mem.span(args[2]);
        const content = readBinaryFile(file_path, MAX_MANIFEST_SIZE) catch |err| {
            printStr("Failed to read manifest file: ");
            printStr(@errorName(err));
            printStr("\n");
            return;
        };
        defer _ = linux.munmap(content.ptr, MAX_MANIFEST_SIZE);

        client.setManifest(target_cid, content) catch |err| {
            printApiError("Set manifest", err);
            return;
        };
        printStr("✓ Manifest successfully staged in hypervisor for CID ");
        var cid_buf: [16]u8 = undefined;
        const cid_str = std.fmt.bufPrint(&cid_buf, "{d}\n", .{target_cid}) catch return;
        printStr(cid_str);
    } else {
        printStr("Unknown manifest subcommand. Available: show, validate, prune, set\n");
    }
}

fn cmdResolve(client: *api.DiosixClient, service_alias: []const u8, manifest_path: ?[]const u8) !void {
    const allocator = std.heap.page_allocator;
    var content_slice: ?[]u8 = null;
    var unmap_len: usize = 0;
    defer {
        if (content_slice) |cs| {
            if (unmap_len > 0) {
                _ = linux.munmap(cs.ptr, unmap_len);
            }
        }
    }

    if (manifest_path) |mp| {
        if (readBinaryFile(mp, MAX_MANIFEST_SIZE)) |c| {
            content_slice = c;
            unmap_len = MAX_MANIFEST_SIZE;
        } else |_| {}
    } else {
        if (readBinaryFile("/etc/diosix/manifest.toml", MAX_MANIFEST_SIZE)) |c| {
            content_slice = c;
            unmap_len = MAX_MANIFEST_SIZE;
        } else |_| {
            if (readBinaryFile("/etc/diosix/system.toml", MAX_MANIFEST_SIZE)) |c| {
                content_slice = c;
                unmap_len = MAX_MANIFEST_SIZE;
            } else |_| {
                var m_buf = try allocator.alloc(u8, MAX_MANIFEST_SIZE);
                defer allocator.free(m_buf);
                if (client.getManifest(CID_SELF, m_buf)) |actual_len| {
                    if (actual_len > 0) {
                        content_slice = try allocator.dupe(u8, m_buf[0..actual_len]);
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
    defer _ = linux.munmap(content.ptr, MAX_MANIFEST_SIZE);

    var out_buf: [MAX_MANIFEST_SIZE]u8 = undefined;
    var out_len: usize = 0;

    var lexer = manifest.ManifestLexer.init(content);
    var cur_cid: usize = 0;
    var cur_name: []const u8 = "";
    var cur_vcpus: usize = 1;
    var cur_ram: []const u8 = "256 MB";
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
                    \\ip = "{s}"
                    \\trust = "{s}"
                    \\status = "{s}"
                    \\
                    \\
                , .{ cur_cid, cur_name, cur_vcpus, cur_ram, cur_ip, cur_trust, cur_status }) catch "";
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

fn saveGuestRegistry(cid: usize, name: []const u8, vcpus: usize, ram: []const u8, ip: []const u8, trust: []const u8, status: []const u8) void {
    removeGuestFromRegistry(cid);
    _ = linux.mkdir("/var/run/diosix", 0o755);

    var entry_buf: [512]u8 = undefined;
    const entry = std.fmt.bufPrint(&entry_buf,
        \\[[guest]]
        \\cid = {d}
        \\name = "{s}"
        \\vcpus = {d}
        \\ram = "{s}"
        \\ip = "{s}"
        \\trust = "{s}"
        \\status = "{s}"
        \\
        \\
    , .{ cid, name, vcpus, ram, ip, trust, status }) catch return;

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
    var ep_buf: [64]u8 = undefined;
    const ep_str = if (std.mem.eql(u8, ip, "local") or cid == 1)
        "local"
    else if (ip.len > 0)
        std.fmt.bufPrint(&ep_buf, "{s} (ipc)", .{ip}) catch ip
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
        "/etc/diosix/keys/id_dropbear",
        "/etc/diosix/keys/id_ed25519",
        "/root/.ssh/id_dropbear",
        "/root/.ssh/id_ed25519",
        "/etc/diosix/id_ed25519",
        "tools/overlay-common/etc/diosix/keys/id_ed25519",
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

fn execSsh(key_path: []const u8, ip_addr: []const u8, remote_cmd: ?[]const u8) !void {
    var key_buf: [128]u8 = undefined;
    if (key_path.len >= key_buf.len) return error.PathTooLong;
    @memcpy(key_buf[0..key_path.len], key_path);
    key_buf[key_path.len] = 0;
    const key_str: [:0]const u8 = key_buf[0..key_path.len :0];

    var dest_buf: [128]u8 = undefined;
    const dest_slice = try std.fmt.bufPrint(dest_buf[0 .. dest_buf.len - 1], "root@{s}", .{ip_addr});
    dest_buf[dest_slice.len] = 0;
    const dest_str: [:0]const u8 = dest_buf[0..dest_slice.len :0];

    var cmd_buf: [512]u8 = undefined;
    const cmd_str: ?[:0]const u8 = if (remote_cmd) |rc| blk: {
        const cs = try std.fmt.bufPrint(cmd_buf[0 .. cmd_buf.len - 1], "{s}", .{rc});
        cmd_buf[cs.len] = 0;
        break :blk cmd_buf[0..cs.len :0];
    } else null;

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
        if (cmd_str) |cs| {
            const exec_argv: [*:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{
                bin,
                "-i",
                key_str.ptr,
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
                key_str.ptr,
                "-y",
                dest_str.ptr,
                null,
            };
            _ = linux.execve(bin, exec_argv, envp);
        }
    }

    printStr("Error: Unable to launch SSH client (tried /usr/bin/ssh, /usr/bin/dbclient, /bin/ssh).\n");
    printStr("Ensure dropbear or openssh client is installed in guest environment.\n");
}

fn cmdRun(client: *api.DiosixClient, args: []const [*:0]const u8) !void {
    const allocator = std.heap.page_allocator;
    if (args.len == 0) {
        printStr("Usage: dsx run <elf_path> [--name <name>] [--vcpus <N>] [--ram <size>] [--ip <ip>] [--manifest <path>] [--domain <domain>] [--trusted] [--arch <arch>]\n");
        printStr("       dsx run --manifest <path> --domain <domain> [--trusted] [--arch <arch>]\n");
        return;
    }

    var elf_path: ?[]const u8 = null;
    var vm_name: ?[]const u8 = null;
    var domain_name: ?[]const u8 = null;
    var manifest_path: ?[]const u8 = null;
    var vcpus: usize = 1;
    var ram_str: []const u8 = "256 MB";
    var ip_str: []const u8 = "";
    var trusted: bool = false;
    var arch_str: []const u8 = "riscv64";
    var dtb_path: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const span = std.mem.span(args[i]);
        if (std.mem.eql(u8, span, "--name") and i + 1 < args.len) {
            i += 1;
            vm_name = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, span, "--domain") and i + 1 < args.len) {
            i += 1;
            domain_name = std.mem.span(args[i]);
        } else if ((std.mem.eql(u8, span, "--manifest") or std.mem.eql(u8, span, "-m")) and i + 1 < args.len) {
            i += 1;
            manifest_path = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, span, "--vcpus") and i + 1 < args.len) {
            i += 1;
            vcpus = std.fmt.parseInt(usize, std.mem.span(args[i]), 10) catch 1;
        } else if (std.mem.eql(u8, span, "--ram") and i + 1 < args.len) {
            i += 1;
            ram_str = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, span, "--ip") and i + 1 < args.len) {
            i += 1;
            ip_str = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, span, "--trusted")) {
            trusted = true;
        } else if (std.mem.eql(u8, span, "--untrusted")) {
            trusted = false;
        } else if (std.mem.eql(u8, span, "--dtb") and i + 1 < args.len) {
            i += 1;
            dtb_path = std.mem.span(args[i]);
        } else if (isArch(span)) {
            arch_str = span;
        } else if (!std.mem.startsWith(u8, span, "-")) {
            if (elf_path == null) {
                elf_path = span;
            }
        }
    }

    if (domain_name) |dname| {
        if (vm_name == null) vm_name = dname;
        const m_file = manifest_path orelse "/etc/diosix/system.toml";
        if (readBinaryFile(m_file, MAX_MANIFEST_SIZE)) |m_content| {
            defer _ = linux.munmap(m_content.ptr, MAX_MANIFEST_SIZE);
            if (manifest.parseSystemManifest(allocator, m_content)) |sys_m| {
                if (sys_m.domains.get(dname)) |dom| {
                    if (elf_path == null and dom.image.len > 0) elf_path = dom.image;
                    if (dom.vcpus > 0 and vcpus == 1) vcpus = dom.vcpus;
                    if (dom.ram.len > 0 and std.mem.eql(u8, ram_str, "256 MB")) ram_str = dom.ram;
                    if (dom.ip.len > 0 and ip_str.len == 0) ip_str = dom.ip;
                }
            } else |_| {}
        } else |_| {}
    }

    if (elf_path == null) {
        printStr("Error: No ELF binary specified. Use 'dsx run <elf_path>' or specify --manifest and --domain.\n");
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

    const elf_data = readBinaryFile(elf_path.?, MAX_ELF_FILE_SIZE) catch |err| {
        if (err == error.FileNotFound) {
            var err_buf: [MAX_PATH_LEN + 64]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "Error: ELF binary '{s}' not found.\n", .{elf_path.?}) catch "Error: ELF binary not found.\n";
            printStr(err_msg);
        } else {
            printApiError("Read ELF", err);
        }
        return;
    };
    defer _ = linux.munmap(elf_data.ptr, MAX_ELF_FILE_SIZE);

    var dtb_data: []u8 = &[_]u8{};
    if (dtb_path) |dp| {
        if (readBinaryFile(dp, MAX_DTB_FILE_SIZE)) |dd| {
            dtb_data = dd;
        } else |_| {}
    }
    defer if (dtb_data.len > 0) {
        _ = linux.munmap(dtb_data.ptr, MAX_DTB_FILE_SIZE);
    };

    var arch_num: usize = @intFromEnum(api.TargetArch.riscv64);
    if (std.mem.eql(u8, arch_str, "riscv32")) {
        arch_num = @intFromEnum(api.TargetArch.riscv32);
    } else if (std.mem.eql(u8, arch_str, "aarch64")) {
        arch_num = @intFromEnum(api.TargetArch.aarch64);
    } else if (std.mem.eql(u8, arch_str, "x86_64")) {
        arch_num = @intFromEnum(api.TargetArch.x86_64);
    }

    const spawn_flags: usize = if (trusted) api.SpawnFlags.TRUSTED else 0;
    const spawned_cid = client.spawn(0, elf_data, dtb_data, arch_num, spawn_flags) catch |err| {
        printApiError("Spawn VM", err);
        return;
    };

    const ram_mb = parseMemorySizeMb(ram_str);
    const ram_pages = (ram_mb * KB_PER_MB) / PAGE_SIZE_KB;
    _ = client.setQuota(spawned_cid, ram_pages, vcpus, 0, 0) catch {};

    if (domain_name) |dname| {
        const m_file = manifest_path orelse "/etc/diosix/system.toml";
        if (readBinaryFile(m_file, MAX_MANIFEST_SIZE)) |m_content| {
            defer _ = linux.munmap(m_content.ptr, MAX_MANIFEST_SIZE);
            if (manifest.parseSystemManifest(allocator, m_content)) |sys_m_val| {
                var sys_m = sys_m_val;
                defer sys_m.deinit();
                if (manifest.pruneSystemManifest(allocator, &sys_m, dname, spawned_cid, CID_SELF, null)) |child_m_val| {
                    var child_m = child_m_val;
                    defer child_m.deinit();
                    if (manifest.serializeChildManifest(allocator, &child_m)) |child_toml| {
                        defer allocator.free(child_toml);
                        _ = client.setManifest(spawned_cid, child_toml) catch {};
                    } else |_| {}
                } else |_| {}
            } else |_| {}
        } else |_| {}
    }

    var final_ip_buf: [64]u8 = undefined;
    const final_ip: []const u8 = if (ip_str.len > 0)
        ip_str
    else
        std.fmt.bufPrint(&final_ip_buf, "10.0.3.{d}", .{spawned_cid}) catch "10.0.3.2";

    var final_ram_buf: [32]u8 = undefined;
    const final_ram_str = std.fmt.bufPrint(&final_ram_buf, "{d} MB", .{ram_mb}) catch "256 MB";

    saveGuestRegistry(spawned_cid, vm_name.?, vcpus, final_ram_str, final_ip, if (trusted) "trusted" else "untrusted", "running");

    var msg_buf: [256]u8 = undefined;
    const out_msg = std.fmt.bufPrint(&msg_buf, "✓ Child VM '{s}' (CID {d}, {d} vCPUs, {s} RAM, IP: {s}) started in background.\n", .{
        vm_name.?,
        spawned_cid,
        vcpus,
        final_ram_str,
        final_ip,
    }) catch return;
    printStr(out_msg);
}

fn cmdList(client: *api.DiosixClient) !void {
    const info_res = client.getInfo() catch null;
    const is_trusted = if (info_res) |info| info.is_trusted != 0 else true;
    const used_vcpus = if (info_res) |info| (if (info.used_vcpus > 0) info.used_vcpus else 4) else 4;
    const ram_mb = if (info_res) |info| ((info.used_ram_pages * PAGE_SIZE_KB) / KB_PER_MB) else 512;
    const child_count = if (info_res) |info| info.child_count else 0;

    printStr("=== Diosix guest VMs ===\n");
    printStr("CID   Name             vCPUs   RAM       Status    Trust       IP / Endpoint\n");

    var self_ram_buf: [32]u8 = undefined;
    const self_ram_str = std.fmt.bufPrint(&self_ram_buf, "{d} MB", .{if (ram_mb > 0) ram_mb else 512}) catch "512 MB";
    printGuestLine(1, "root (self)", used_vcpus, self_ram_str, "running", if (is_trusted) "trusted" else "untrusted", "local");

    var guest_count: usize = 0;
    if (readBinaryFile("/var/run/diosix/guests.toml", MAX_MANIFEST_SIZE)) |content| {
        defer _ = linux.munmap(content.ptr, MAX_MANIFEST_SIZE);
        var lexer = manifest.ManifestLexer.init(content);

        var cur_cid: usize = 0;
        var cur_name: []const u8 = "";
        var cur_vcpus: usize = 1;
        var cur_ram: []const u8 = "256 MB";
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

var g_ipc_resp_buf: [2048]u8 = undefined;

fn sendIpcCommand(client: *api.DiosixClient, target_cid: usize, cmd: []const u8) ![]const u8 {
    try client.sendIpc(target_cid, cmd);

    var tries: usize = 0;
    while (tries < 100) : (tries += 1) {
        if (client.recvIpc(0, &g_ipc_resp_buf) catch null) |msg| {
            if (msg.data.len > 0) {
                return msg.data;
            }
        }
        const ts = linux.timespec{ .sec = 0, .nsec = 10_000_000 }; // 10ms
        _ = linux.nanosleep(&ts, null);
    }
    return "Error: No response from child VM (timed out).";
}

fn readStdinLine(buf: []u8) !usize {
    var total_read: usize = 0;
    while (total_read < buf.len) {
        var byte_buf: [1]u8 = undefined;
        const n = linux.read(linux.STDIN_FILENO, &byte_buf, 1);
        if (n <= 0) {
            if (total_read == 0) return 0; // EOF
            break;
        }
        const c = byte_buf[0];
        if (c == '\n' or c == '\r') {
            break;
        }
        buf[total_read] = c;
        total_read += 1;
    }
    return total_read;
}

fn cmdLogin(client: *api.DiosixClient, args: []const [*:0]const u8) !void {
    if (args.len == 0) {
        printStr("Usage: dsx login <name|cid> [-- [command...]]\n");
        printStr("       dsx ssh <name|cid> [-- [command...]]\n");
        printStr("       dsx console <name|cid>\n");
        return;
    }

    const target_str = std.mem.span(args[0]);
    var remote_cmd: ?[]const u8 = null;

    if (args.len > 1) {
        var start_idx: usize = 1;
        if (std.mem.eql(u8, std.mem.span(args[1]), "--")) {
            start_idx = 2;
        }
        if (args.len > start_idx) {
            var cmd_buf = std.ArrayList(u8).empty;
            const allocator = std.heap.page_allocator;
            for (args[start_idx..]) |arg| {
                const s = std.mem.span(arg);
                if (cmd_buf.items.len > 0) try cmd_buf.append(allocator, ' ');
                try cmd_buf.appendSlice(allocator, s);
            }
            remote_cmd = cmd_buf.items;
        }
    }

    var resolved_cid: usize = parseCid(target_str) catch 0;
    var resolved_name: []const u8 = target_str;
    var resolved_ip: []const u8 = "";

    var ip_storage: [64]u8 = undefined;
    var name_storage: [64]u8 = undefined;

    if (std.mem.eql(u8, target_str, "root") or std.mem.eql(u8, target_str, "self") or resolved_cid == 1) {
        resolved_cid = 1;
        resolved_name = "root";
        resolved_ip = "127.0.0.1";
    }

    if (readBinaryFile("/var/run/diosix/guests.toml", MAX_MANIFEST_SIZE)) |content| {
        defer _ = linux.munmap(content.ptr, MAX_MANIFEST_SIZE);
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
            defer _ = linux.munmap(content.ptr, MAX_MANIFEST_SIZE);
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
        } else {
            resolved_ip = "127.0.0.1";
        }
    }

    // Direct Hypervisor Inter-VM IPC communication for child VMs
    if (resolved_cid >= CID_FIRST_CHILD) {
        if (remote_cmd) |rc| {
            var msg_buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "Executing on child VM '{s}' (CID {d} via Diosix IPC): {s}\n", .{
                resolved_name,
                resolved_cid,
                rc,
            }) catch return;
            printStr(msg);

            const resp = sendIpcCommand(client, resolved_cid, rc) catch |err| {
                printApiError("IPC send to guest", err);
                return;
            };
            printStr(resp);
            printStr("\n");
            return;
        }

        var banner_buf: [256]u8 = undefined;
        const banner = std.fmt.bufPrint(&banner_buf,
            \\Connected to child VM '{s}' (CID {d} via Diosix IPC).
            \\Type 'help' for available commands, 'exit' or Ctrl+D to disconnect.
            \\
            \\
        , .{ resolved_name, resolved_cid }) catch "";
        printStr(banner);

        var line_buf: [256]u8 = undefined;
        while (true) {
            var prompt_buf: [64]u8 = undefined;
            const prompt = std.fmt.bufPrint(&prompt_buf, "{s}# ", .{resolved_name}) catch "> ";
            printStr(prompt);

            const line_len = readStdinLine(&line_buf) catch break;
            if (line_len == 0) {
                printStr("\nConnection closed.\n");
                break;
            }

            const line = trimWhitespace(line_buf[0..line_len]);
            if (std.mem.eql(u8, line, "exit") or std.mem.eql(u8, line, "quit")) {
                printStr("Connection closed.\n");
                break;
            }
            if (line.len == 0) continue;

            const resp = sendIpcCommand(client, resolved_cid, line) catch |err| {
                printApiError("IPC send to guest", err);
                continue;
            };
            if (resp.len > 0) {
                printStr(resp);
                printStr("\n");
            }
        }
        return;
    }

    // Local Root VM SSH fallback
    const key_file = findPrivateKey() orelse {
        printStr("Error: No SSH private key found (/etc/diosix/keys/id_ed25519 or /root/.ssh/id_ed25519).\n");
        return;
    };

    if (remote_cmd) |rc| {
        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Executing on local Root VM (CID 1): {s}\n", .{rc}) catch return;
        printStr(msg);
    } else {
        printStr("Logging into local Root VM (CID 1)...\n");
    }

    try execSsh(key_file, "127.0.0.1", remote_cmd);
}

fn cmdStop(client: *api.DiosixClient, args: []const [*:0]const u8) !void {
    if (args.len == 0) {
        printStr("Usage: dsx stop <name|cid>\n");
        return;
    }
    const target_str = std.mem.span(args[0]);
    var target_cid = parseCid(target_str) catch 0;
    var target_name: []const u8 = target_str;

    var name_storage: [64]u8 = undefined;

    if (readBinaryFile("/var/run/diosix/guests.toml", MAX_MANIFEST_SIZE)) |content| {
        defer _ = linux.munmap(content.ptr, MAX_MANIFEST_SIZE);
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
        printStr("Error: Invalid or unknown child VM identifier.\n");
        return;
    }

    client.terminate(target_cid, 0) catch |err| {
        printApiError("Stop VM", err);
        return;
    };
    removeGuestFromRegistry(target_cid);

    var msg_buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "✓ Child VM '{s}' (CID {d}) terminated.\n", .{ target_name, target_cid }) catch return;
    printStr(msg);
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
    defer _ = linux.munmap(content.ptr, 1024);
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
        \\name = "sys-supervisor"
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
                if (std.mem.eql(u8, cur_name, "sys-supervisor")) found_sys = true;
            }
            break;
        }
        if (tok.tag == .bracket_open) {
            if (cur_cid >= CID_FIRST_CHILD) {
                guest_count += 1;
                if (std.mem.eql(u8, cur_name, "user")) found_user = true;
                if (std.mem.eql(u8, cur_name, "sys-supervisor")) found_sys = true;
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
    try testing.expect(matchTarget("sys", 0, 3, "sys-supervisor"));
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


