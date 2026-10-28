// Diosix Hypervisor Guest Management CLI — VM Lifecycle & Resource Quotas.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const api = @import("api.zig");
const common = @import("common.zig");
const vm_info = @import("vm/info.zig");
const vm_run = @import("vm/run.zig");
const vm_install = @import("vm/install.zig");
const vm_restart = @import("vm/restart.zig");
const vm_console = @import("vm/console.zig");

pub const formatGuestDetail = vm_info.formatGuestDetail;
pub const formatSelfInfo = vm_info.formatSelfInfo;
pub const cmdInfo = vm_info.cmdInfo;
pub const cmdRun = vm_run.cmdRun;
pub const cmdInstallGuest = vm_install.cmdInstallGuest;
pub const cmdRestart = vm_restart.cmdRestart;
pub const cmdConsole = vm_console.cmdConsole;

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
const parseMemorySizeMb = common.parseMemorySizeMb;
const readBinaryFile = common.readBinaryFile;
const unmapBinaryFile = common.unmapBinaryFile;
const matchTarget = common.matchTarget;
const removeGuestFromRegistry = common.removeGuestFromRegistry;
const printGuestLine = common.printGuestLine;

const QuotaOption = enum {
    @"--ram",
    @"--pcpu",
    @"--pcpu-quota",
    @"--vcpus",
    @"--depth",
    @"--descendants",
};

const TargetAlias = common.TargetAlias;

pub fn cmdQuota(
    client: *api.DiosixClient,
    target_cid: usize,
    argv: []const [*:0]const u8,
) !void {
    var ram_pages: usize = 0;
    var pcpu_pct: usize = 0;
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
            continue;
        }
        if (std.meta.stringToEnum(QuotaOption, flag)) |opt| {
            switch (opt) {
                .@"--ram" => {
                    if (i + 1 >= argv.len) {
                        printStr(
                            "Error: Option '--ram' requires a value in MB.\n",
                        );
                        return;
                    }
                    i += 1;
                    const raw_val = std.mem.span(argv[i]);
                    const mb = std.fmt.parseInt(usize, raw_val, 10) catch blk: {
                        const parsed = parseMemorySizeMb(raw_val);
                        if (parsed == 0) {
                            printStr(
                                "Error: Invalid numeric value for '--ram'.\n",
                            );
                            return;
                        }
                        break :blk parsed;
                    };
                    ram_pages = (mb * KB_PER_MB) / PAGE_SIZE_KB;
                    has_update = true;
                },
                .@"--pcpu", .@"--pcpu-quota" => {
                    if (i + 1 >= argv.len) {
                        printStr(
                            "Error: '--pcpu' requires a percentage (1-90).\n",
                        );
                        return;
                    }
                    i += 1;
                    const raw_pct = std.mem.trimEnd(
                        u8,
                        std.mem.span(argv[i]),
                        "%",
                    );
                    pcpu_pct = std.fmt.parseInt(usize, raw_pct, 10) catch {
                        printStr(
                            "Error: Invalid numeric value for '--pcpu'.\n",
                        );
                        return;
                    };
                    if (pcpu_pct == 0 or
                        pcpu_pct > api.MAX_CHILD_PCPU_QUOTA_PCT)
                    {
                        printStr(
                            "Error: '--pcpu' must be between 1 and 90%.\n",
                        );
                        return;
                    }
                    has_update = true;
                },
                .@"--vcpus" => {
                    if (i + 1 >= argv.len) {
                        printStr("Error: Option '--vcpus' requires a value.\n");
                        return;
                    }
                    i += 1;
                    vcpus = std.fmt.parseInt(
                        usize,
                        std.mem.span(argv[i]),
                        10,
                    ) catch {
                        printStr(
                            "Error: Invalid numeric value for '--vcpus'.\n",
                        );
                        return;
                    };
                    has_update = true;
                },
                .@"--depth" => {
                    if (i + 1 >= argv.len) {
                        printStr("Error: Option '--depth' requires a value.\n");
                        return;
                    }
                    i += 1;
                    depth = std.fmt.parseInt(
                        usize,
                        std.mem.span(argv[i]),
                        10,
                    ) catch {
                        printStr(
                            "Error: Invalid numeric value for '--depth'.\n",
                        );
                        return;
                    };
                    has_update = true;
                },
                .@"--descendants" => {
                    if (i + 1 >= argv.len) {
                        printStr(
                            "Error: Option '--descendants' requires a value.\n",
                        );
                        return;
                    }
                    i += 1;
                    descendants = std.fmt.parseInt(
                        usize,
                        std.mem.span(argv[i]),
                        10,
                    ) catch {
                        printStr(
                            "Error: Invalid numeric value for " ++
                                "'--descendants'.\n",
                        );
                        return;
                    };
                    has_update = true;
                },
            }
        } else if (std.mem.startsWith(u8, flag, "-")) {
            common.printFmt(
                "Error: Unknown option '{s}'. Available: --pcpu, --ram, " ++
                    "--vcpus, --depth, --descendants.\n",
                .{flag},
            );
            return;
        }
    }

    if (!has_update) {
        if (client.getInfo(target_cid)) |info| {
            const used_ram_mb =
                (info.used_ram_pages * PAGE_SIZE_KB) / KB_PER_MB;
            const max_ram_mb = if (info.max_ram_pages == std.math.maxInt(usize))
                0
            else
                (info.max_ram_pages * PAGE_SIZE_KB) / KB_PER_MB;
            const self_ram_mb =
                (info.self_ram_pages * PAGE_SIZE_KB) / KB_PER_MB;
            const del_ram_mb =
                (info.delegated_ram_pages * PAGE_SIZE_KB) / KB_PER_MB;
            const avail_ram_mb = max_ram_mb -| @max(del_ram_mb, used_ram_mb);
            const self_vcpus = if (info.vcpus > 0) info.vcpus else 4;
            const pcpu_q: u32 = if (info.pcpu_quota_pct > 0)
                info.pcpu_quota_pct
            else
                100;
            const del_pcpu: u32 = @min(
                info.delegated_pcpu_pct,
                api.MAX_CHILD_PCPU_QUOTA_PCT,
            );
            const ret_pcpu: u32 = 100 -| del_pcpu;

            const q_fmt =
                "Resource Quotas (CID {d}):\n" ++
                "  Logical Config : {d} vCPUs, {d} MB RAM\n" ++
                "  pCPU Quota     : {d}% ({d}% delegated to children, " ++
                "{d}% retained)\n" ++
                "  RAM Quota Pool : {d} MB in use / {d} MB max " ++
                "({d} MB delegated, {d} MB available)\n" ++
                "  Child VMs      : {d} active\n";
            common.printFmt(q_fmt, .{
                target_cid,
                self_vcpus,
                self_ram_mb,
                pcpu_q,
                del_pcpu,
                ret_pcpu,
                used_ram_mb,
                max_ram_mb,
                del_ram_mb,
                avail_ram_mb,
                info.child_count,
            });
            return;
        } else |err| {
            printApiError("Query quotas", err);
            return;
        }
    }

    client.setQuotaWithPcpu(
        target_cid,
        ram_pages,
        vcpus,
        depth,
        descendants,
        pcpu_pct,
        0,
    ) catch |err| {
        printApiError("Set quota", err);
        return;
    };
    printStr("Quotas updated successfully.\n");
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
    const info_res = client.getInfo(1) catch null;
    const is_root = if (info_res) |info| info.is_root != 0 else true;
    const is_trusted = if (info_res) |info| info.is_trusted != 0 else true;
    const default_self_vcpus: usize = if (is_root) 4 else 1;
    const self_vcpus = if (info_res) |info|
        (if (info.vcpus > 0) info.vcpus else default_self_vcpus)
    else
        4;
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
        "CID   Name             vCPUs   RAM       Status    Trust       " ++
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
    const self_name = if (is_root) "root (self)" else "self";
    printGuestLine(
        1,
        self_name,
        self_vcpus,
        self_ram_str,
        "running",
        if (is_trusted) "trusted" else "untrusted",
        "local",
    );

    var guest_count: usize = 0;
    if (readBinaryFile(
        GUEST_REGISTRY_PATH,
        MAX_MANIFEST_SIZE,
    )) |content| {
        defer unmapBinaryFile(content);
        var iter = common.GuestRegistryIter.init(content);
        while (iter.next()) |entry| {
            const c_mb = parseMemorySizeMb(entry.ram);
            const child_ram_str = allocator.print("{d} MB", .{c_mb}) catch {
                printStr("Error: Out of memory formatting VM list.\n");
                return;
            };
            defer allocator.free(child_ram_str);
            printGuestLine(
                entry.cid,
                entry.name,
                entry.vcpus,
                child_ram_str,
                entry.status,
                entry.trust,
                entry.ip,
            );
            guest_count += 1;
        }
    } else |_| {}

    if (guest_count == 0 and child_count == 0) {
        printStr("\nNo child VMs running.\n");
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
                if (client.getInfo(1)) |info| {
                    if (info.is_root != 0) {
                        common.printFmt(
                            "Root VM cannot be stopped directly. Use " ++
                                "'{s} host poweroff' or '{s} host reboot'.\n",
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
        printApiError("Stop VM", err);
        return false;
    };
    removeGuestFromRegistry(target_cid);

    common.printFmt(
        "✓ Child VM '{s}' (CID {d}) terminated.\n",
        .{ target_name, target_cid },
    );
    return true;
}

test "vm: QuotaOption enum parses expected CLI flags" {
    std.testing.refAllDecls(@This());
    _ = vm_info;
    _ = vm_run;
    _ = vm_install;
    _ = vm_restart;
    _ = vm_console;
    try std.testing.expectEqual(
        QuotaOption.@"--ram",
        std.meta.stringToEnum(QuotaOption, "--ram").?,
    );
}
