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
        \\dsx / diosix-ctl: Diosix Hypervisor Guest Management Tool
        \\
        \\Usage:
        \\  dsx info [--host]                  Display current VM state (or host hypervisor info)
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
    } else {
        const msg = std.fmt.bufPrint(&buf, "Error: {s} failed (hypercall or permission error).\n", .{action}) catch return;
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
    if ((flags & api.ForkFlags.UNTRUSTED) != 0) {
        printStr("Forking current VM (dropping hardware trust for child)...\n");
    } else {
        printStr("Forking current VM...\n");
    }
    const child_cid = client.fork(flags) catch |err| {
        printApiError("Fork", err);
        return;
    };
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
