// Diosix Constitutional Charter & Steward Quorum CLI (dsx charter).
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const api = @import("../api.zig");
const charter = @import("../charter.zig");
const whisper = @import("../whisper.zig");
const common = @import("../common.zig");

const MAX_MANIFEST_SIZE = common.MAX_MANIFEST_SIZE;
const printStr = common.printStr;
const parseCid = common.parseCid;
const printApiError = common.printApiError;
const readBinaryFile = common.readBinaryFile;
const unmapBinaryFile = common.unmapBinaryFile;

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
const CharterProposeOption = enum {
    @"--unit",
    @"--count",
    @"--total",
    @"--quorum",
};

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
    var subcmd: []const u8 = "status";
    var arg_start: usize = 0;
    if (args.len > 0) {
        const first = std.mem.span(args[0]);
        if (!std.mem.startsWith(u8, first, "-")) {
            subcmd = first;
            arg_start = 1;
        }
    }

    var file_path: []const u8 = charter.DEFAULT_CHARTER_PATH;
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
        var err_buf: [128]u8 = undefined;
        const err_msg = std.fmt.bufPrint(
            &err_buf,
            "Error: Unknown charter subcommand '{s}'. " ++
                "Use '{s} charter help'.\n",
            .{ subcmd, exe_name },
        ) catch return;
        printStr(err_msg);
        return;
    };

    switch (cmd) {
        .help, .@"--help" => {
            var buf: [1536]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf,
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
            , .{exe_name}) catch return;
            printStr(msg);
        },
        .status => cmdCharterStatus(client, file_path, json_mode),
        .deploy, .seal => cmdCharterDeploy(client, file_path, json_mode),
        .propose => cmdCharterPropose(args, arg_start, file_path, json_mode),
        .ratify => {
            var target_cid: usize = 1;
            var i: usize = arg_start;
            while (i < args.len) : (i += 1) {
                const span = std.mem.span(args[i]);
                if (std.mem.eql(u8, span, "--target") and i + 1 < args.len) {
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
            var out_buf: [256]u8 = undefined;
            const out = if (json_mode)
                std.fmt.bufPrint(
                    &out_buf,
                    "{{\"status\":\"ratified\",\"target_cid\":{d}," ++
                        "\"ratified_mask\":{d}}}\n",
                    .{ target_cid, bitmap },
                ) catch return
            else
                std.fmt.bufPrint(
                    &out_buf,
                    "✓ Recorded Steward ratification vote for target " ++
                        "CID {d} (mask: 0x{x}).\n",
                    .{ target_cid, bitmap },
                ) catch return;
            printStr(out);
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
                if (std.mem.eql(u8, span, "--standby") and i + 1 < args.len) {
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
        .audit => {
            var file_digest: [32]u8 = @splat(0);
            var file_hex: [64]u8 = @splat('0');
            var file_ok = false;
            if (readBinaryFile(file_path, MAX_MANIFEST_SIZE)) |content| {
                defer unmapBinaryFile(content);
                charter.computeCharterSha256(content, &file_digest, &file_hex);
                file_ok = true;
            } else |_| {}

            var mmode_sealed = false;
            var hash_matches = false;
            if (client.getCharter()) |hv_c| {
                mmode_sealed = hv_c.is_sealed != 0;
                hash_matches = mmode_sealed and
                    std.mem.eql(u8, &hv_c.charter_hash, &file_digest);
            } else |_| {}

            var out_buf: [512]u8 = undefined;
            if (json_mode) {
                const jfmt =
                    "{{\"charter_file_present\":{s},\"mmode_sealed\":{s}," ++
                    "\"sha256_verified\":{s}}}\n";
                const jout = std.fmt.bufPrint(&out_buf, jfmt, .{
                    if (file_ok) "true" else "false",
                    if (mmode_sealed) "true" else "false",
                    if (hash_matches) "true" else "false",
                }) catch return;
                printStr(jout);
            } else {
                const match_str = if (hash_matches)
                    "verified"
                else
                    "unverified (seal with 'dsx charter deploy')";
                const out = std.fmt.bufPrint(&out_buf,
                    \\=== Constitutional Audit ===
                    \\  Charter file present : {s}
                    \\  M-mode Charter sealed: {s}
                    \\  SHA-256 hash match   : {s}
                    \\
                , .{
                    if (file_ok) "yes" else "no",
                    if (mmode_sealed) "yes" else "no",
                    match_str,
                }) catch return;
                printStr(out);
            }
        },
    }
}

fn cmdCharterStatus(
    client: *api.DiosixClient,
    file_path: []const u8,
    json_mode: bool,
) void {
    var parsed = charter.ParsedCharter{};
    var file_loaded = false;
    if (readBinaryFile(file_path, MAX_MANIFEST_SIZE)) |content| {
        defer unmapBinaryFile(content);
        if (charter.parseCharterToml(content)) |p| {
            parsed = p;
            file_loaded = true;
        } else |_| {}
    } else |_| {}

    var hv_sealed = false;
    var hv_hash_hex: [64]u8 = @splat('0');
    var hv_ratified_mask: u64 = 0;
    var hv_failover_epoch: u64 = 0;
    if (client.getCharter()) |hv_c| {
        hv_sealed = hv_c.is_sealed != 0;
        const hex_chars = "0123456789abcdef";
        for (hv_c.charter_hash, 0..) |b, idx| {
            hv_hash_hex[idx * 2] = hex_chars[b >> 4];
            hv_hash_hex[idx * 2 + 1] = hex_chars[b & 0x0f];
        }
        hv_ratified_mask = hv_c.ratified_mask;
        hv_failover_epoch = hv_c.failover_epoch;
    } else |_| {}

    var out_buf: [2048]u8 = undefined;
    if (json_mode) {
        const json_fmt =
            "{{\"file\":\"{s}\",\"file_loaded\":{s},\"id\":\"{s}\"," ++
            "\"version\":{d},\"file_sha256\":\"{s}\"," ++
            "\"mmode_sealed\":{s},\"mmode_sha256\":\"{s}\"," ++
            "\"quorum_required\":{d},\"quorum_total\":{d}," ++
            "\"min_stewards\":{d},\"standby_replicas\":{d}," ++
            "\"unit_count\":{d},\"ratified_mask\":{d}," ++
            "\"failover_epoch\":{d}}}\n";
        const jout = std.fmt.bufPrint(&out_buf, json_fmt, .{
            file_path,               if (file_loaded) "true" else "false",
            parsed.id(),             parsed.version,
            &parsed.sha256_hex,      if (hv_sealed) "true" else "false",
            &hv_hash_hex,            parsed.quorum_required,
            parsed.quorum_total,     parsed.min_stewards,
            parsed.standby_replicas, parsed.unit_count,
            hv_ratified_mask,        hv_failover_epoch,
        }) catch return;
        printStr(jout);
    } else {
        const seal_str = if (hv_sealed)
            "sealed in M-mode"
        else
            "unsealed (pending deploy)";
        const load_str = if (file_loaded) "loaded" else "defaults";
        const max_term = parsed.max_simultaneous_unit_termination_pct;
        const out = std.fmt.bufPrint(&out_buf,
            \\=== Diosix Constitutional Charter ===
            \\  Charter file       : {s} ({s})
            \\  Constitution doc   : {s}
            \\  Charter ID         : {s} (v{d})
            \\  Charter SHA-256    : {s}
            \\  M-mode enforcement : {s}
            \\  Steward quorum     : {d}-of-{d} (min stewards: {d})
            \\  Standby Root VMs   : {d} (failover epoch: {d})
            \\  Workload units     : {d} (max termination: {d}%)
            \\
        , .{
            file_path,                         load_str,
            charter.DEFAULT_CONSTITUTION_PATH, parsed.id(),
            parsed.version,                    &parsed.sha256_hex,
            seal_str,                          parsed.quorum_required,
            parsed.quorum_total,               parsed.min_stewards,
            parsed.standby_replicas,           hv_failover_epoch,
            parsed.unit_count,                 max_term,
        }) catch return;
        printStr(out);
    }
}

fn cmdCharterDeploy(
    client: *api.DiosixClient,
    file_path: []const u8,
    json_mode: bool,
) void {
    const content = readBinaryFile(file_path, MAX_MANIFEST_SIZE) catch |err| {
        printApiError("Read Constitutional Charter", err);
        return;
    };
    defer unmapBinaryFile(content);
    const parsed = charter.parseCharterToml(content) catch {
        printStr("Error: Invalid Constitutional Charter TOML config.\n");
        return;
    };
    const c_args = parsed.toSbiArgs(true);
    client.sealCharter(&c_args) catch |err| {
        printApiError("Seal Constitutional Charter in M-mode", err);
        return;
    };
    var out_buf: [512]u8 = undefined;
    const args_tuple = .{
        parsed.id(),            &parsed.sha256_hex,
        parsed.quorum_required, parsed.quorum_total,
    };
    const out = if (json_mode)
        std.fmt.bufPrint(
            &out_buf,
            "{{\"status\":\"sealed\",\"id\":\"{s}\",\"sha256\":\"{s}\"," ++
                "\"quorum_required\":{d},\"quorum_total\":{d}}}\n",
            args_tuple,
        ) catch return
    else
        std.fmt.bufPrint(
            &out_buf,
            "✓ Constitutional Charter '{s}' sealed in M-mode " ++
                "(SHA-256: {s}, quorum: {d}-of-{d}).\n",
            args_tuple,
        ) catch return;
    printStr(out);
}

fn cmdCharterPropose(
    args: []const [*:0]const u8,
    arg_start: usize,
    file_path: []const u8,
    json_mode: bool,
) void {
    if (arg_start >= args.len) {
        printStr(
            "Error: 'charter propose' requires an action " ++
                "(amend_charter, terminate_steward, reset_steward, " ++
                "root_failover, terminate_units, delete_volume, " ++
                "export_volume, enable_wan_egress).\n",
        );
        return;
    }
    const action_str = std.mem.span(args[arg_start]);
    const action = parseProposalAction(action_str) orelse {
        printStr("Error: Unknown proposal action.\n");
        return;
    };

    var parsed = charter.ParsedCharter{};
    if (readBinaryFile(file_path, MAX_MANIFEST_SIZE)) |content| {
        defer unmapBinaryFile(content);
        if (charter.parseCharterToml(content)) |p| parsed = p else |_| {}
    } else |_| {}

    var unit_id: []const u8 = "";
    var affected_count: u32 = 1;
    var total_count: u32 = parsed.min_stewards;
    var has_quorum = false;

    var i: usize = arg_start + 1;
    while (i < args.len) : (i += 1) {
        const span = std.mem.span(args[i]);
        if (std.meta.stringToEnum(CharterProposeOption, span)) |opt| {
            switch (opt) {
                .@"--unit" => if (i + 1 < args.len) {
                    i += 1;
                    unit_id = std.mem.span(args[i]);
                },
                .@"--count" => if (i + 1 < args.len) {
                    i += 1;
                    const s = std.mem.span(args[i]);
                    affected_count =
                        std.fmt.parseInt(u32, s, 10) catch affected_count;
                },
                .@"--total" => if (i + 1 < args.len) {
                    i += 1;
                    const s = std.mem.span(args[i]);
                    total_count =
                        std.fmt.parseInt(u32, s, 10) catch total_count;
                },
                .@"--quorum" => has_quorum = true,
            }
        }
    }

    const res = charter.verifyProposalAgainstInvariants(
        &parsed,
        action,
        unit_id,
        affected_count,
        total_count,
        has_quorum,
    );
    var out_buf: [512]u8 = undefined;
    const mark = if (res.allowed) "✓" else "✗";
    const al_str = if (res.allowed) "true" else "false";
    const rq_str = if (res.requires_quorum) "true" else "false";
    const j_fmt = "{{\"action\":\"{s}\",\"allowed\":{s}," ++
        "\"requires_quorum\":{s},\"reason\":\"{s}\"}}\n";
    const out = if (json_mode)
        std.fmt.bufPrint(
            &out_buf,
            j_fmt,
            .{ action_str, al_str, rq_str, res.reason },
        ) catch return
    else
        std.fmt.bufPrint(
            &out_buf,
            "{s} Proposal '{s}': {s}\n",
            .{ mark, action_str, res.reason },
        ) catch return;
    printStr(out);
}

test "charter_cmd: parseProposalAction maps CLI proposal verbs" {
    std.testing.refAllDecls(@This());
    const A = charter.ProposalAction;
    const p1 = parseProposalAction("amend-charter").?;
    const p2 = parseProposalAction("promote-standby-root").?;
    try std.testing.expectEqual(A.amend_charter, p1);
    try std.testing.expectEqual(A.root_failover, p2);
    try std.testing.expect(parseProposalAction("invalid") == null);
}
