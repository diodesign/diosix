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
    } else if (std.mem.eql(u8, command, "drop-trust")) {
        try cmdDropTrust(&client);
    } else if (std.mem.eql(u8, command, "quota")) {
        if (argv.len < 3) {
            printStr("Usage: dsx quota <cid|self> [--ram <MB>] [--vcpus <N>] [--depth <N>] [--descendants <N>]\n");
            return;
        }
        const target_cid = try parseCid(std.mem.span(argv[2]));
        try cmdQuota(&client, target_cid, argv);
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
        \\  dsx quota <cid|self> [options]     Set or lower VM resource quotas (--ram, --vcpus, --descendants)
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

    const mmap_res = linux.mmap(null, file_size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE }, fd, 0);
    const mmap_signed: isize = @bitCast(mmap_res);
    if (mmap_signed < 0) {
        // Fallback to anonymous buffer if file-backed mmap fails (e.g. sysfs files)
        const anon_res = linux.mmap(null, max_size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
        const anon_signed: isize = @bitCast(anon_res);
        if (anon_signed < 0) return error.OutOfMemory;
        const buf: [*]u8 = @ptrFromInt(anon_res);
        var total_read: usize = 0;
        while (total_read < max_size) {
            const read_res = linux.read(fd, buf + total_read, max_size - total_read);
            const r_signed: isize = @bitCast(read_res);
            if (r_signed <= 0) break;
            total_read += @intCast(r_signed);
        }
        return buf[0..total_read];
    }
    const buf: [*]u8 = @ptrFromInt(mmap_res);
    return buf[0..file_size];
}

fn unmapBinaryFile(slice: []const u8) void {
    if (slice.len > 0) {
        _ = linux.munmap(slice.ptr, slice.len);
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
        defer unmapBinaryFile(content);

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

fn runSshCommand(key_str: ?[:0]const u8, dest_str: [:0]const u8, cmd_str: ?[:0]const u8) u32 {
    const pid_res = linux.fork();
    const pid_signed: isize = @bitCast(pid_res);
    if (pid_signed < 0) return 255;
    if (pid_signed == 0) {
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

fn execSsh(key_path: ?[]const u8, ip_addr: []const u8, remote_cmd: ?[]const u8) !void {
    var key_buf: [128]u8 = undefined;
    const key_str: ?[:0]const u8 = if (key_path) |kp| blk: {
        if (kp.len >= key_buf.len) return error.PathTooLong;
        @memcpy(key_buf[0..kp.len], kp);
        key_buf[kp.len] = 0;
        break :blk key_buf[0..kp.len :0];
    } else null;

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

    const max_attempts: usize = if (std.mem.eql(u8, ip_addr, "127.0.0.1") or std.mem.eql(u8, ip_addr, "localhost")) 1 else 30;
    var attempts: usize = 0;
    var printed_waiting = false;

    while (attempts < max_attempts) : (attempts += 1) {
        const status = runSshCommand(key_str, dest_str, cmd_str);
        if (status == 0) return;

        if (!printed_waiting and attempts < max_attempts - 1) {
            printStr("Waiting for guest to finish booting and start SSH service...\n");
            printed_waiting = true;
        }

        var req = linux.timespec{ .sec = 2, .nsec = 0 };
        var rem: linux.timespec = undefined;
        _ = linux.nanosleep(&req, &rem);
    }
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
            defer unmapBinaryFile(m_content);
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

    var final_ip_buf: [64]u8 = undefined;
    const final_ip: []const u8 = if (ip_str.len > 0)
        ip_str
    else
        std.fmt.bufPrint(&final_ip_buf, "10.0.3.{d}", .{child_cid}) catch "10.0.3.2";

    var final_ram_buf: [32]u8 = undefined;
    const final_ram_str = std.fmt.bufPrint(&final_ram_buf, "{d} MB", .{ram_mb}) catch "256 MB";

    saveGuestRegistry(child_cid, vm_name.?, vcpus, final_ram_str, final_ip, if (trusted) "trusted" else "untrusted", "running");

    var msg_buf: [256]u8 = undefined;
    const out_msg = std.fmt.bufPrint(&msg_buf, "✓ Child VM '{s}' (CID {d}, {d} vCPUs, {s} RAM, IP: {s}) started in background.\n", .{
        vm_name.?,
        child_cid,
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

    printStr("CID   Name             vCPUs   RAM       Status    Trust       IP / Endpoint\n");

    var self_ram_buf: [32]u8 = undefined;
    const self_ram_str = std.fmt.bufPrint(&self_ram_buf, "{d} MB", .{if (ram_mb > 0) ram_mb else 512}) catch "512 MB";
    printGuestLine(1, "root (self)", used_vcpus, self_ram_str, "running", if (is_trusted) "trusted" else "untrusted", "local");

    var guest_count: usize = 0;
    if (readBinaryFile("/var/run/diosix/guests.toml", MAX_MANIFEST_SIZE)) |content| {
        defer unmapBinaryFile(content);
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

fn cmdLogin(client: *api.DiosixClient, args: []const [*:0]const u8) !void {
    _ = client;
    if (args.len == 0) {
        printStr("Usage: dsx login <name|cid> [-- [command...]]\n");
        printStr("       dsx ssh <name|cid> [-- [command...]]\n");
        return;
    }

    const target_str = std.mem.span(args[0]);
    var remote_cmd: ?[]const u8 = null;

    var cmd_str_buf: [512]u8 = undefined;
    if (args.len > 1) {
        var start_idx: usize = 1;
        if (std.mem.eql(u8, std.mem.span(args[1]), "--")) {
            start_idx = 2;
        }
        if (args.len > start_idx) {
            var buf_len: usize = 0;
            for (args[start_idx..]) |arg| {
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
        } else {
            resolved_ip = "127.0.0.1";
        }
    }

    const key_file = findPrivateKey();

    if (remote_cmd) |rc| {
        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Connecting to guest '{s}' ({s}): {s}\n", .{ resolved_name, resolved_ip, rc }) catch return;
        printStr(msg);
    } else {
        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Connecting to guest '{s}' ({s}) via SSH...\n", .{ resolved_name, resolved_ip }) catch return;
        printStr(msg);
    }

    try execSsh(key_file, resolved_ip, remote_cmd);
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
