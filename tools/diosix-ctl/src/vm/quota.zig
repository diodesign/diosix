// Diosix Hypervisor Guest Management CLI — Resource Quota Commands.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const api = @import("../api.zig");
const common = @import("../common.zig");

const CID_PARENT = common.CID_PARENT;
const PAGE_SIZE_KB = common.PAGE_SIZE_KB;
const KB_PER_MB = common.KB_PER_MB;
const printStr = common.printStr;
const printApiError = common.printApiError;
const parseMemorySizeMb = common.parseMemorySizeMb;

const QuotaOption = enum {
    @"--ram",
    @"--pcpu",
    @"--pcpu-quota",
    @"--retained-pcpu",
    @"--vcpus",
    @"--depth",
    @"--descendants",
};

/// Queries or updates symmetric resource quotas for `target_cid`.
pub fn cmdQuota(
    client: *api.DiosixClient,
    target_cid: usize,
    argv: []const [*:0]const u8,
) !void {
    var ram_pages: usize = 0;
    var pcpu_pct: usize = 0;
    var retained_pcpu_pct: usize = 0;
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
        if (i == 2 and !std.mem.startsWith(u8, flag, "-")) continue;
        if (std.meta.stringToEnum(QuotaOption, flag)) |opt| {
            switch (opt) {
                .@"--ram" => {
                    if (i + 1 >= argv.len) {
                        return printStr(
                            "Error: Option '--ram' requires a value in MB.\n",
                        );
                    }
                    i += 1;
                    const raw_val = std.mem.span(argv[i]);
                    const mb = std.fmt.parseInt(usize, raw_val, 10) catch blk: {
                        const parsed = parseMemorySizeMb(raw_val);
                        if (parsed == 0) {
                            return printStr(
                                "Error: Invalid numeric value for '--ram'.\n",
                            );
                        }
                        break :blk parsed;
                    };
                    ram_pages = (mb * KB_PER_MB) / PAGE_SIZE_KB;
                    has_update = true;
                },
                .@"--pcpu", .@"--pcpu-quota" => {
                    if (i + 1 >= argv.len) {
                        return printStr(
                            "Error: '--pcpu' requires a percentage (1-90).\n",
                        );
                    }
                    i += 1;
                    const raw_pct = std.mem.trimEnd(
                        u8,
                        std.mem.span(argv[i]),
                        "%",
                    );
                    pcpu_pct = std.fmt.parseInt(usize, raw_pct, 10) catch {
                        return printStr(
                            "Error: Invalid numeric value for '--pcpu'.\n",
                        );
                    };
                    if (pcpu_pct == 0 or pcpu_pct > 99) {
                        return printStr(
                            "Error: '--pcpu' must be between 1 and 99%.\n",
                        );
                    }
                    has_update = true;
                },
                .@"--retained-pcpu" => {
                    if (i + 1 >= argv.len) {
                        printStr(
                            "Error: '--retained-pcpu' requires a percentage " ++
                                "(1-99).\n",
                        );
                        return;
                    }
                    i += 1;
                    const raw_ret = std.mem.trimEnd(
                        u8,
                        std.mem.span(argv[i]),
                        "%",
                    );
                    retained_pcpu_pct = std.fmt.parseInt(
                        usize,
                        raw_ret,
                        10,
                    ) catch {
                        printStr(
                            "Error: Invalid numeric value for " ++
                                "'--retained-pcpu'.\n",
                        );
                        return;
                    };
                    if (retained_pcpu_pct == 0 or retained_pcpu_pct > 99) {
                        printStr(
                            "Error: '--retained-pcpu' must be between 1 " ++
                                "and 99%.\n",
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
                "Error: Unknown option '{s}'. Available: --pcpu, " ++
                    "--retained-pcpu, --ram, --vcpus, --depth, " ++
                    "--descendants.\n",
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
            const avail_ram_mb = max_ram_mb -| @max(
                self_ram_mb +| del_ram_mb,
                used_ram_mb,
            );
            const self_vcpus = if (info.vcpus > 0) info.vcpus else 1;
            const pcpu_q: u32 = if (info.pcpu_quota_pct > 0)
                info.pcpu_quota_pct
            else
                100;
            const min_ret: u32 = @min(
                pcpu_q -| 1,
                api.DEFAULT_RETAINED_PCPU_PCT,
            );
            const max_del: u32 = pcpu_q -| min_ret;
            const del_pcpu: u32 = @min(info.delegated_pcpu_pct, max_del);
            const ret_pcpu: u32 = pcpu_q -| del_pcpu;

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

    const eff_pcpu_arg =
        if (retained_pcpu_pct > 0) retained_pcpu_pct else pcpu_pct;
    client.setQuotaWithPcpu(
        target_cid,
        ram_pages,
        vcpus,
        depth,
        descendants,
        eff_pcpu_arg,
        0,
    ) catch |err| {
        printApiError("Set quota", err);
        return;
    };
    printStr("Quotas updated successfully.\n");
}

test "vm/quota: QuotaOption enum parses expected CLI flags" {
    std.testing.refAllDecls(@This());
    try std.testing.expectEqual(
        QuotaOption.@"--ram",
        std.meta.stringToEnum(QuotaOption, "--ram").?,
    );
    try std.testing.expectEqual(
        QuotaOption.@"--retained-pcpu",
        std.meta.stringToEnum(QuotaOption, "--retained-pcpu").?,
    );
}
