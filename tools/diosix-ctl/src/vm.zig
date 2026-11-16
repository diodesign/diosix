// Diosix Hypervisor Guest Management CLI — VM Lifecycle & Resource Quotas.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const api = @import("api.zig");
const common = @import("common.zig");
const net = @import("net.zig");
const vm_info = @import("vm/info.zig");
const vm_run = @import("vm/run.zig");
const vm_install = @import("vm/install.zig");
const vm_restart = @import("vm/restart.zig");
const vm_console = @import("vm/console.zig");
const vm_quota = @import("vm/quota.zig");

pub const formatGuestDetail = vm_info.formatGuestDetail;
pub const formatSelfInfo = vm_info.formatSelfInfo;
pub const cmdInfo = vm_info.cmdInfo;
pub const cmdRun = vm_run.cmdRun;
pub const cmdInstallGuest = vm_install.cmdInstallGuest;
pub const cmdRestart = vm_restart.cmdRestart;
pub const cmdConsole = vm_console.cmdConsole;
pub const cmdQuota = vm_quota.cmdQuota;

const CID_PARENT = common.CID_PARENT;
const CID_SELF = common.CID_SELF;
const CID_FIRST_CHILD = common.CID_FIRST_CHILD;
const MAX_MANIFEST_SIZE = common.MAX_MANIFEST_SIZE;
const GUEST_REGISTRY_PATH = common.GUEST_REGISTRY_PATH;
const PAGE_SIZE_KB = common.PAGE_SIZE_KB;
const KB_PER_MB = common.KB_PER_MB;

const printStr = common.printStr;
const parseCid = common.parseCid;
const printApiError = common.printApiError;
const readBinaryFile = common.readBinaryFile;
const unmapBinaryFile = common.unmapBinaryFile;
const matchTarget = common.matchTarget;
const removeGuestFromRegistry = common.removeGuestFromRegistry;
const printGuestLine = common.printGuestLine;

const TargetAlias = common.TargetAlias;

fn parseMemorySizeMb(s: []const u8) usize {
    return common.parseMemorySizeMb(s);
}

fn readSelfHostname(buf: *[64]u8) []const u8 {
    if (readBinaryFile("/etc/hostname", 256)) |content| {
        defer unmapBinaryFile(content);
        const trimmed = common.trimWhitespace(content);
        if (trimmed.len > 0) return common.copyStr(buf, trimmed);
    } else |_| {}
    return "self";
}

pub fn cmdDropTrust(client: *api.DiosixClient) !void {
    printStr("Dropping hardware trust...\n");
    client.dropTrust() catch |err| {
        printApiError("Drop trust", err);
        return;
    };
    printStr("Hardware trust successfully relinquished.\n");
}

pub fn cmdList(client: *api.DiosixClient) !void {
    const info_res = client.getInfo(CID_SELF) catch null;
    const is_trusted = if (info_res) |info| info.is_trusted != 0 else true;
    const default_self_vcpus: usize = 1;
    const self_vcpus = if (info_res) |info|
        (if (info.vcpus > 0) info.vcpus else default_self_vcpus)
    else
        1;
    const default_ram: usize = 256;
    const ram_mb = if (info_res) |info|
        (if (info.self_ram_pages > 0)
            ((info.self_ram_pages * PAGE_SIZE_KB) / KB_PER_MB)
        else
            default_ram)
    else
        default_ram;
    const child_count = if (info_res) |info| info.child_count else 0;

    printStr(
        "CID  Name                 vCPUs  RAM      Status   Trust     " ++
            "IP / Endpoint\n",
    );

    const allocator = std.heap.page_allocator;
    const self_ram_str = allocator.print(
        "{d} MB",
        .{if (ram_mb > 0) ram_mb else default_ram},
    ) catch {
        printStr("Error: Out of memory formatting VM list.\n");
        return;
    };
    defer allocator.free(self_ram_str);

    var host_buf: [64]u8 = undefined;
    var self_lbl_buf: [80]u8 = undefined;
    const self_name = std.fmt.bufPrint(
        &self_lbl_buf,
        "{s} (self)",
        .{readSelfHostname(&host_buf)},
    ) catch "self";
    const trust_str = if (is_trusted) "trusted" else "untrusted";
    const parent_lbl = if (info_res) |info|
        (if (info.has_parent != 0)
            "local (parent:CID0)"
        else
            "local (hypervisor)")
    else
        "local";
    printGuestLine(
        1,
        self_name,
        self_vcpus,
        self_ram_str,
        "running",
        trust_str,
        parent_lbl,
    );

    var total_active: usize = 0;
    if (readBinaryFile(GUEST_REGISTRY_PATH, MAX_MANIFEST_SIZE)) |content| {
        defer unmapBinaryFile(content);
        var c_iter = common.GuestRegistryIter.init(content);
        while (c_iter.next()) |entry| {
            if (client.dev_fd != null and
                (client.getInfo(entry.cid) catch null) == null)
            {
                net.applyHostFirewall(entry.cid, entry.ip, .none, 0);
                removeGuestFromRegistry(entry.cid);
                continue;
            }
            total_active += 1;
        }
    } else |_| {}

    var guest_count: usize = 0;
    if (total_active > 0) {
        if (readBinaryFile(GUEST_REGISTRY_PATH, MAX_MANIFEST_SIZE)) |content| {
            defer unmapBinaryFile(content);
            var iter = common.GuestRegistryIter.init(content);
            while (iter.next()) |entry| {
                const c_mb = parseMemorySizeMb(entry.ram);
                const child_ram_str = allocator.print(
                    "{d} MB",
                    .{c_mb},
                ) catch {
                    printStr("Error: Out of memory formatting VM list.\n");
                    return;
                };
                defer allocator.free(child_ram_str);
                guest_count += 1;
                const branch = if (guest_count == total_active)
                    "└─ "
                else
                    "├─ ";
                var tree_name_buf: [96]u8 = undefined;
                const tree_name = std.fmt.bufPrint(
                    &tree_name_buf,
                    "{s}{s}",
                    .{ branch, entry.name },
                ) catch entry.name;
                printGuestLine(
                    entry.cid,
                    tree_name,
                    entry.vcpus,
                    child_ram_str,
                    entry.status,
                    entry.trust,
                    entry.ip,
                );
            }
        } else |_| {}
    }

    if (guest_count == 0 and child_count == 0) {
        printStr("\nNo direct child VMs running.\n");
    } else {
        printStr("\nNote: child subtrees are opaque; only direct children " ++
            "are visible.\n");
    }
}

pub fn cmdStop(client: *api.DiosixClient, args: []const [*:0]const u8) !bool {
    const exe_name = common.getExeName();
    if (args.len == 0) {
        common.printFmt("Usage: {s} stop <name|cid|self>\n", .{exe_name});
        return false;
    }
    const target_str = std.mem.span(args[0]);
    if (std.meta.stringToEnum(TargetAlias, target_str)) |alias| {
        switch (alias) {
            .parent, .@"0" => {
                printStr("Error: Cannot stop parent VM (CID 0).\n");
                return false;
            },
            .self, .current => {
                if (client.getInfo(CID_SELF)) |info| {
                    if (info.has_parent == 0) {
                        common.printFmt(
                            "Top-level VM cannot be stopped with " ++
                                "'stop self'. Use '{s} host poweroff' or " ++
                                "'{s} host reboot'.\n",
                            .{ exe_name, exe_name },
                        );
                        return false;
                    }
                } else |_| {}
                client.terminate(CID_SELF, 0) catch |err| {
                    printApiError("Stop self", err);
                    return false;
                };
                printStr("VM self-terminated.\n");
                return true;
            },
            .root => {},
        }
    }

    var target_cid = parseCid(target_str) catch 0;
    var target_name: []const u8 = target_str;
    // Registry names live in a mapping released below, so keep a heap copy.
    var owned_name: ?[]u8 = null;
    defer if (owned_name) |owned| std.heap.page_allocator.free(owned);

    if (readBinaryFile(
        GUEST_REGISTRY_PATH,
        MAX_MANIFEST_SIZE,
    )) |content| {
        defer unmapBinaryFile(content);
        var iter = common.GuestRegistryIter.init(content);
        while (iter.next()) |entry| {
            if (matchTarget(target_str, target_cid, entry.cid, entry.name)) {
                target_cid = entry.cid;
                const copy = std.heap.page_allocator.dupe(
                    u8,
                    entry.name,
                ) catch {
                    printStr("Error: Out of memory reading VM name.\n");
                    return false;
                };
                owned_name = copy;
                target_name = copy;
                break;
            }
        }
    } else |_| {}

    if (target_cid < CID_FIRST_CHILD) {
        common.printFmt(
            "Error: Unknown or invalid child VM '{s}'. " ++
                "Use '{s} list' to inspect active VMs.\n",
            .{ target_str, exe_name },
        );
        return false;
    }

    client.terminate(target_cid, 0) catch |err| {
        if (client.dev_fd != null and
            (client.getInfo(target_cid) catch null) == null)
        {
            net.applyHostFirewall(target_cid, "", .none, 0);
            removeGuestFromRegistry(target_cid);
        }
        printApiError("Stop VM", err);
        return false;
    };
    net.applyHostFirewall(target_cid, "", .none, 0);
    removeGuestFromRegistry(target_cid);

    common.printFmt(
        "✓ Child VM '{s}' (CID {d}) terminated.\n",
        .{ target_name, target_cid },
    );
    return true;
}

test "vm: submodules compile cleanly and self hostname reads non-empty" {
    std.testing.refAllDecls(@This());
    _ = vm_info;
    _ = vm_run;
    _ = vm_install;
    _ = vm_restart;
    _ = vm_console;
    _ = vm_quota;
    var buf: [64]u8 = undefined;
    try std.testing.expect(readSelfHostname(&buf).len > 0);
}
