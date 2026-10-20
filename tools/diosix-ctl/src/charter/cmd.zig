// Diosix Constitutional Charter & Steward Quorum CLI (dsx charter).
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const api = @import("../api.zig");
const charter = @import("../charter.zig");
const whisper = @import("../whisper.zig");
const common = @import("../common.zig");
const status = @import("status.zig");

pub const cmdCharterStatus = status.cmdCharterStatus;
pub const cmdCharterDeploy = status.cmdCharterDeploy;
pub const cmdCharterPropose = status.cmdCharterPropose;
pub const cmdCharterAudit = status.cmdCharterAudit;

const printStr = common.printStr;
const printFmt = common.printFmt;
const parseCid = common.parseCid;
const printApiError = common.printApiError;

const CharterSubcommand = enum {
    help,
    @"--help",
    status,
    deploy,
    seal,
    propose,
    ratify,
    whisper,
    @"reset-steward",
    failover,
    audit,
};

const CharterCommonOption = enum { @"--json", @"-j", @"--file", @"-f" };
const CharterRatifyOption = enum { @"--target" };
const CharterFailoverOption = enum { @"--standby" };

const ProposalActionAlias = enum {
    amend_charter,
    @"amend-charter",
    terminate_steward,
    @"terminate-steward",
    @"retire-steward",
    reset_steward,
    @"reset-steward",
    root_failover,
    @"root-failover",
    @"promote-standby-root",
    terminate_units,
    @"terminate-units",
    @"terminate-vm",
    delete_volume,
    @"delete-volume",
    export_volume,
    @"export-volume",
    enable_wan_egress,
    @"enable-wan-egress",
};

pub fn parseProposalAction(str: []const u8) ?charter.ProposalAction {
    if (std.meta.stringToEnum(ProposalActionAlias, str)) |alias| {
        return switch (alias) {
            .amend_charter, .@"amend-charter" => .amend_charter,
            .terminate_steward,
            .@"terminate-steward",
            .@"retire-steward",
            => .terminate_steward,
            .reset_steward, .@"reset-steward" => .reset_steward,
            .root_failover,
            .@"root-failover",
            .@"promote-standby-root",
            => .root_failover,
            .terminate_units,
            .@"terminate-units",
            .@"terminate-vm",
            => .terminate_units,
            .delete_volume, .@"delete-volume" => .delete_volume,
            .export_volume, .@"export-volume" => .export_volume,
            .enable_wan_egress, .@"enable-wan-egress" => .enable_wan_egress,
        };
    }
    return null;
}

pub fn cmdCharter(
    client: *api.DiosixClient,
    args: []const [*:0]const u8,
) !void {
    const exe_name = common.getExeName();
    const sys_cfg = common.loadRuntimeSystemConfig();
    var subcmd: []const u8 = "status";
    var arg_start: usize = 0;
    if (args.len > 0) {
        const first = std.mem.span(args[0]);
        if (!std.mem.startsWith(u8, first, "-")) {
            subcmd = first;
            arg_start = 1;
        }
    }

    var file_path: []const u8 = sys_cfg.charterConfigPath();
    var json_mode = false;
    for (args[arg_start..], arg_start..) |arg, idx| {
        const span = std.mem.span(arg);
        if (std.meta.stringToEnum(CharterCommonOption, span)) |opt| {
            switch (opt) {
                .@"--json", .@"-j" => json_mode = true,
                .@"--file", .@"-f" => if (idx + 1 < args.len) {
                    file_path = std.mem.span(args[idx + 1]);
                },
            }
        }
    }

    const cmd = std.meta.stringToEnum(CharterSubcommand, subcmd) orelse {
        printFmt(
            "Error: Unknown charter subcommand '{s}'. " ++
                "Use '{s} charter help'.\n",
            .{ subcmd, exe_name },
        );
        return;
    };

    switch (cmd) {
        .help, .@"--help" => printFmt(
            \\Usage: {s} charter <subcmd> [options]
            \\
            \\Subcommands:
            \\  status [--file <path>] [--json]      Show Charter state
            \\  deploy [--file <path>] [--json]      Seal Charter in M-mode
            \\  propose <action> [options] [--json]  Evaluate proposal
            \\      [--unit <id>]                    Target unit ID
            \\      [--count <N>] [--total <M>]      Unit/Steward counts
            \\      [--quorum]                       Mark quorum ratified
            \\  ratify [--target <cid>] [--json]     Cast ratification vote
            \\  whisper <send|recv> [opts] [--json]  Whisper Protocol IPC
            \\  reset-steward <cid> [--json]         Reset Steward VM
            \\  failover [--standby <cid>] [--json]  Promote Standby Root
            \\  audit [--file <path>] [--json]       Audit M-mode Charter
            \\
        , .{exe_name}),
        .status => cmdCharterStatus(client, file_path, json_mode),
        .deploy, .seal => cmdCharterDeploy(client, file_path, json_mode),
        .propose => cmdCharterPropose(args, arg_start, file_path, json_mode),
        .ratify => {
            var target_cid: usize = 1;
            var i: usize = arg_start;
            while (i < args.len) : (i += 1) {
                const span = std.mem.span(args[i]);
                if (std.meta.stringToEnum(CharterRatifyOption, span) != null and
                    i + 1 < args.len)
                {
                    i += 1;
                    target_cid = parseCid(std.mem.span(args[i])) catch 1;
                } else if (!std.mem.startsWith(u8, span, "-")) {
                    target_cid = parseCid(span) catch 1;
                }
            }
            const bitmap = client.ratifyCharter(target_cid) catch |err| {
                printApiError("Ratify Constitutional Charter action", err);
                return;
            };
            if (json_mode) {
                printFmt(
                    "{{\"status\":\"ratified\",\"target_cid\":{d}," ++
                        "\"ratified_mask\":{d}}}\n",
                    .{ target_cid, bitmap },
                );
            } else {
                printFmt(
                    "✓ Recorded Steward ratification vote for target " ++
                        "CID {d} (mask: 0x{x}).\n",
                    .{ target_cid, bitmap },
                );
            }
        },
        .whisper => whisper.cmdCharterWhisper(args, arg_start, json_mode),
        .@"reset-steward" => {
            if (arg_start >= args.len) {
                printStr(
                    "Error: 'charter reset-steward' requires a Steward CID.\n",
                );
                return;
            }
            const target_cid = parseCid(std.mem.span(args[arg_start])) catch {
                printStr("Error: Invalid Steward CID.\n");
                return;
            };
            _ = client.resetSteward(target_cid) catch |err| {
                printApiError("Reset Steward VM", err);
                return;
            };
            printStr(if (json_mode)
                "{\"status\":\"reset\"}\n"
            else
                "✓ Steward VM reset to clean M-mode measurement " ++
                    "and entry point.\n");
        },
        .failover => {
            var standby_cid: usize = 0;
            var i: usize = arg_start;
            while (i < args.len) : (i += 1) {
                const span = std.mem.span(args[i]);
                if (std.meta.stringToEnum(
                    CharterFailoverOption,
                    span,
                ) != null and i + 1 < args.len) {
                    i += 1;
                    standby_cid = parseCid(std.mem.span(args[i])) catch 0;
                } else if (!std.mem.startsWith(u8, span, "-")) {
                    standby_cid = parseCid(span) catch 0;
                }
            }
            _ = client.requestRootFailover(standby_cid) catch |err| {
                printApiError("Promote Standby Root VM", err);
                return;
            };
            printStr(if (json_mode)
                "{\"status\":\"promoted\"}\n"
            else
                "✓ Standby Root VM promoted via M-mode " ++
                    "Constitutional Guard.\n");
        },
        .audit => cmdCharterAudit(client, file_path, json_mode),
    }
}

test "charter_cmd: parseProposalAction maps CLI proposal verbs" {
    std.testing.refAllDecls(@This());
    _ = status;
    const A = charter.ProposalAction;
    const p1 = parseProposalAction("amend-charter").?;
    const p2 = parseProposalAction("promote-standby-root").?;
    try std.testing.expectEqual(A.amend_charter, p1);
    try std.testing.expectEqual(A.root_failover, p2);
    try std.testing.expect(parseProposalAction("invalid") == null);
}
