// Diosix Hypervisor Guest Management CLI
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const api = @import("diosix_api.zig");
const linux = std.os.linux;

fn printStr(str: []const u8) void {
    _ = linux.write(1, str.ptr, str.len);
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
        try cmdInfo(&client);
    } else if (std.mem.eql(u8, command, "fork")) {
        try cmdFork(&client);
    } else if (std.mem.eql(u8, command, "drop-trust")) {
        try cmdDropTrust(&client);
    } else if (std.mem.eql(u8, command, "spawn")) {
        if (argv.len < 4) {
            printStr("Usage: diosix-ctl spawn <child_id> <elf_path> [dtb_path] [arch]\n");
            return;
        }
        const child_id = try std.fmt.parseInt(usize, std.mem.span(argv[2]), 10);
        const elf_path = std.mem.span(argv[3]);
        const dtb_path: ?[]const u8 = if (argv.len > 4) std.mem.span(argv[4]) else null;
        const arch_str = if (argv.len > 5) std.mem.span(argv[5]) else "riscv64";
        try cmdSpawn(&client, child_id, elf_path, dtb_path, arch_str);
    } else if (std.mem.eql(u8, command, "terminate") or std.mem.eql(u8, command, "kill") or std.mem.eql(u8, command, "exit")) {
        const target_id = if (argv.len > 2) try std.fmt.parseInt(usize, std.mem.span(argv[2]), 10) else 0;
        try cmdTerminate(&client, target_id);
    } else if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help")) {
        printUsage();
    } else {
        printStr("Unknown command. Use 'diosix-ctl help' for available commands.\n");
    }
}

fn printUsage() void {
    const usage =
        \\diosix-ctl: Diosix Hypervisor Guest Management Tool
        \\
        \\Usage:
        \\  diosix-ctl info                           Display current VM state, ID, and quotas
        \\  diosix-ctl fork                           Fork current VM to create a child VM
        \\  diosix-ctl spawn <id> <elf> [dtb] [arch]  Load a new guest image into child VM and start it
        \\  diosix-ctl terminate [vm_id]              Terminate specified child VM ID (or 0 for self)
        \\  diosix-ctl drop-trust                     Irrevocably drop hardware trust privileges
        \\  diosix-ctl help                           Show this help message
        \\
    ;
    printStr(usage);
}


fn cmdTerminate(client: *api.DiosixClient, target_id: usize) !void {
    if (target_id == 0) {
        printStr("Terminating current VM...\n");
    } else {
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Terminating child VM {d} and all descendants...\n", .{target_id}) catch return;
        printStr(msg);
    }
    client.terminate(target_id) catch {
        printStr("Terminate failed (permission denied or invalid VM ID).\n");
        return;
    };
    printStr("VM successfully terminated.\n");
}

fn cmdInfo(client: *api.DiosixClient) !void {
    const info = client.getInfo() catch |err| {
        if (err == error.DeviceNotFound) {
            printStr("Error: /dev/diosix not found. Ensure diosix kernel driver is enabled.\n");
        } else {
            printStr("Error: Hypercall failed querying hypervisor info.\n");
        }
        return;
    };

    const arch_name = switch (info.target_arch) {
        0 => "riscv64",
        1 => "riscv32",
        2 => "aarch64",
        3 => "x86_64",
        else => "unknown",
    };

    const is_root_str = if (info.is_root != 0) "yes" else "no";
    const is_trusted_str = if (info.is_trusted != 0) "yes" else "no";
    const ram_mb = (info.used_ram_pages * 4) / 1024;

    var buf: [512]u8 = undefined;
    const out = std.fmt.bufPrint(&buf,
        \\=== Diosix Guest VM Info ===
        \\Guest ID       : {d}
        \\Parent ID      : {d}
        \\Architecture   : {s}
        \\Root VM        : {s}
        \\Hardware Trust : {s}
        \\RAM Allocation : {d} MB ({d} pages)
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


fn cmdFork(client: *api.DiosixClient) !void {
    printStr("Forking current VM...\n");
    const child_id = client.fork() catch {
        printStr("Fork failed.\n");
        return;
    };
    var buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Successfully forked child VM with ID: {d}\n", .{child_id}) catch return;
    printStr(msg);
}

fn cmdDropTrust(client: *api.DiosixClient) !void {
    printStr("Dropping hardware trust...\n");
    client.dropTrust() catch {
        printStr("Drop trust failed.\n");
        return;
    };
    printStr("Hardware trust successfully relinquished.\n");
}

fn cmdSpawn(client: *api.DiosixClient, child_id: usize, elf_path: []const u8, dtb_path: ?[]const u8, arch_str: []const u8) !void {
    printStr("Loading guest ELF image...\n");

    var path_buf: [256]u8 = undefined;
    if (elf_path.len >= path_buf.len) return error.PathTooLong;
    @memcpy(path_buf[0..elf_path.len], elf_path);
    path_buf[elf_path.len] = 0;

    const fd_res = linux.open(@ptrCast(path_buf[0..elf_path.len :0]), .{ .ACCMODE = .RDONLY }, 0);
    const fd_signed: isize = @bitCast(fd_res);
    if (fd_signed < 0) {
        printStr("Failed to open ELF file.\n");
        return;
    }
    const fd: i32 = @intCast(fd_signed);
    defer _ = linux.close(fd);

    // Read up to 64MB using page allocation via mmap
    const max_len: usize = 64 * 1024 * 1024;
    const mmap_res = linux.mmap(null, max_len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
    const mmap_signed: isize = @bitCast(mmap_res);
    if (mmap_signed < 0) {
        printStr("Memory allocation failed.\n");
        return;
    }
    const buf: [*]u8 = @ptrFromInt(mmap_res);
    defer _ = linux.munmap(buf, max_len);

    var total_read: usize = 0;
    while (total_read < max_len) {
        const read_res = linux.read(fd, buf + total_read, max_len - total_read);
        const r_signed: isize = @bitCast(read_res);
        if (r_signed <= 0) break;
        total_read += @intCast(r_signed);
    }

    if (total_read == 0) {
        printStr("ELF file is empty or unreadable.\n");
        return;
    }

    const dtb_data: []u8 = &[_]u8{};
    _ = dtb_path;


    var arch_num: usize = 0;
    if (std.mem.eql(u8, arch_str, "riscv32")) {
        arch_num = 1;
    } else if (std.mem.eql(u8, arch_str, "aarch64")) {
        arch_num = 2;
    } else if (std.mem.eql(u8, arch_str, "x86_64")) {
        arch_num = 3;
    }

    printStr("Spawning child VM...\n");
    client.spawn(child_id, buf[0..total_read], dtb_data, arch_num) catch {
        printStr("Spawn failed.\n");
        return;
    };
    printStr("Child VM successfully spawned and started.\n");
}
