// Diosix Charter Dissemination & Quota-Stake Voting Operations.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const api = @import("../api.zig");
const charter = @import("../charter.zig");
const common = @import("../common.zig");
const net_http = @import("../net/http.zig");
const sysconfig = @import("../sysconfig.zig");
const amend = @import("amend.zig");
const crypto = @import("crypto.zig");

const VoteOption = enum {
    @"--file",
    @"-f",
    @"--approve",
    @"-a",
    @"--reject",
    @"--auto",
    @"--port",
    @"-p",
    @"--json",
    @"-j",
};

pub const VoteMode = enum { auto, approve, reject };

pub const VoteOutcome = struct {
    parsed: charter.ParsedCharter,
    decision: api.MissionVoteDecision,
    check: amend.AmendmentCheckResult,
    vote_args: api.MissionVoteArgs,
};

pub fn saveActiveCharterFile(content: []const u8) void {
    net_http.ensureParentDir(sysconfig.ACTIVE_CHARTER_STATE_PATH);
    common.writeFile(sysconfig.ACTIVE_CHARTER_STATE_PATH, content) catch {};
}

pub fn savePendingCharterFile(content: []const u8) void {
    net_http.ensureParentDir(sysconfig.CHARTER_PENDING_PATH);
    common.writeFile(sysconfig.CHARTER_PENDING_PATH, content) catch {};
}

pub fn loadActiveCharterFile() ?charter.ParsedCharter {
    const raw = common.readBinaryFile(
        sysconfig.ACTIVE_CHARTER_STATE_PATH,
        common.MAX_MANIFEST_SIZE,
    ) catch return null;
    defer common.unmapBinaryFile(raw);
    return charter.parseCharterToml(raw) catch null;
}

pub fn postProposalToBoard(
    allocator: std.mem.Allocator,
    ip_be: u32,
    port: u16,
    content: []const u8,
    parsed: *const charter.ParsedCharter,
) !void {
    const toml_esc = try common.escapeJsonAlloc(allocator, content);
    defer allocator.free(toml_esc);
    const id_esc = try common.escapeJsonAlloc(allocator, parsed.id());
    defer allocator.free(id_esc);

    const inner = try allocator.print(
        "{{\"kind\":\"charter_proposal\",\"id\":\"{s}\"," ++
            "\"version\":{d},\"sha256\":\"{s}\",\"toml\":\"{s}\"}}",
        .{ id_esc, parsed.version, &parsed.sha256_hex, toml_esc },
    );
    defer allocator.free(inner);
    const body_esc = try common.escapeJsonAlloc(allocator, inner);
    defer allocator.free(body_esc);

    const payload = try allocator.print(
        "{{\"topic\":\"charter\",\"target_cid\":0,\"body\":\"{s}\"}}",
        .{body_esc},
    );
    defer allocator.free(payload);

    const resp = try net_http.httpClientRequest(
        allocator,
        ip_be,
        port,
        "POST",
        "/v1/messages",
        "application/json",
        payload,
        64 * 1024,
    );
    defer resp.deinit(allocator);
    if (resp.status >= 400) return error.BoardRejected;
}

pub fn evaluateProposalAgainstState(
    client: *api.DiosixClient,
    proposed: *const charter.ParsedCharter,
) amend.AmendmentCheckResult {
    var has_mmode = false;
    var mmode_info = std.mem.zeroes(api.MissionArgs);
    if (client.getMission(null)) |mi| {
        mmode_info = mi;
        has_mmode = mi.is_sealed != 0;
    } else |_| {}

    if (has_mmode and mmode_info.has_pubkey != 0) {
        if (!crypto.verifyCharterSignature(
            proposed,
            mmode_info.principal_pubkey,
        )) {
            return .{
                .allowed = false,
                .reason = "Invalid signature for sealed M-mode Principal key",
            };
        }
        if (proposed.version <= mmode_info.version) {
            return .{
                .allowed = false,
                .reason = "Amendment rejects M-mode version rollback/replay",
            };
        }
        const m_prot =
            (mmode_info.flags & api.MissionFlags.PROTECT_REPLICAS) != 0;
        const m_enc = (mmode_info.flags &
            api.MissionFlags.FORBID_UNRATIFIED_ENCRYPT) != 0;
        if (m_enc and (proposed.encrypt_volumes or proposed.wipe_volumes)) {
            return .{
                .allowed = false,
                .reason = "M-mode guard forbids volume encryption/wipe",
            };
        }
        const prop_reps = proposed.totalMinReplicas();
        if (m_prot and mmode_info.min_total_replicas > 0 and prop_reps == 0) {
            return .{
                .allowed = false,
                .reason = "M-mode floor blocks dropping replicas to zero",
            };
        }
        if (m_prot and prop_reps < mmode_info.min_total_replicas) {
            const lost: u64 = mmode_info.min_total_replicas - prop_reps;
            const lim: u64 = @as(u64, mmode_info.min_total_replicas) *
                @as(u64, mmode_info.max_stepdown_pct);
            if (lost * 100 > lim) {
                return .{
                    .allowed = false,
                    .reason = "M-mode floor blocks excessive replica drop",
                };
            }
        }
    } else if (proposed.hasPrincipalPubkey()) {
        if (!crypto.verifyCharterSignature(proposed, null)) {
            return .{
                .allowed = false,
                .reason = "Invalid Ed25519 signature over Charter",
            };
        }
    }

    if (loadActiveCharterFile()) |active| {
        return amend.verifyCharterAmendment(&active, proposed);
    }
    if (proposed.wipe_volumes or
        (proposed.forbid_unratified_encryption and proposed.encrypt_volumes))
    {
        return .{
            .allowed = false,
            .reason = "Ransomware guard blocks unratified volume mutation",
        };
    }
    return .{ .allowed = true, .reason = "Signature and invariants valid" };
}

pub fn postVoteReceiptToParent(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    port: u16,
    out: *const VoteOutcome,
) void {
    if (!net_http.isHasParent(client)) return;
    const dec_s = if (out.decision == .approve) "approve" else "reject";
    const r_esc = common.escapeJsonAlloc(allocator, out.check.reason) catch
        return;
    defer allocator.free(r_esc);
    const inner = allocator.print(
        "{{\"kind\":\"charter_vote\",\"version\":{d},\"sha256\":\"{s}\"," ++
            "\"decision\":\"{s}\",\"stake_pages\":{d},\"reason\":\"{s}\"}}",
        .{
            out.parsed.version,
            &out.parsed.sha256_hex,
            dec_s,
            out.vote_args.caller_stake_pages,
            r_esc,
        },
    ) catch return;
    defer allocator.free(inner);
    const b_esc = common.escapeJsonAlloc(allocator, inner) catch return;
    defer allocator.free(b_esc);
    const payload = allocator.print(
        "{{\"topic\":\"charter-vote\",\"target_cid\":0,\"body\":\"{s}\"}}",
        .{b_esc},
    ) catch return;
    defer allocator.free(payload);

    const ip_be = net_http.resolveParentIpv4(client);
    const resp = net_http.httpClientRequest(
        allocator,
        ip_be,
        port,
        "POST",
        "/v1/messages",
        "application/json",
        payload,
        16384,
    ) catch return;
    resp.deinit(allocator);
}

pub fn castMissionVote(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    proposed_content: []const u8,
    mode: VoteMode,
    board_port: u16,
) !VoteOutcome {
    const parsed = try charter.parseCharterToml(proposed_content);
    const check = evaluateProposalAgainstState(client, &parsed);
    const decision: api.MissionVoteDecision = switch (mode) {
        .approve => .approve,
        .reject => .reject,
        .auto => if (check.allowed) .approve else .reject,
    };
    const v_res = try client.voteMission(parsed.sha256_bytes, decision);
    const outcome = VoteOutcome{
        .parsed = parsed,
        .decision = decision,
        .check = check,
        .vote_args = v_res,
    };
    postVoteReceiptToParent(allocator, client, board_port, &outcome);
    return outcome;
}

pub fn cmdCharterDisseminate(
    args: []const [*:0]const u8,
    arg_start: usize,
    default_file: []const u8,
    json_mode: bool,
) void {
    const alloc = std.heap.page_allocator;
    var file_path = default_file;
    var port: u16 = sysconfig.DEFAULT_BOARD_PORT;
    var json_f = json_mode;
    var i: usize = arg_start;
    while (i < args.len) : (i += 1) {
        const s = std.mem.span(args[i]);
        const opt = std.meta.stringToEnum(VoteOption, s) orelse continue;
        switch (opt) {
            .@"--file", .@"-f" => if (i + 1 < args.len) {
                i += 1;
                file_path = std.mem.span(args[i]);
            },
            .@"--port", .@"-p" => if (i + 1 < args.len) {
                i += 1;
                port = std.fmt.parseInt(u16, std.mem.span(args[i]), 10) catch
                    sysconfig.DEFAULT_BOARD_PORT;
            },
            .@"--json", .@"-j" => json_f = true,
            else => {},
        }
    }
    const content = common.readBinaryFile(
        file_path,
        common.MAX_MANIFEST_SIZE,
    ) catch |e| {
        common.printApiError("Read Charter TOML", e);
        return;
    };
    defer common.unmapBinaryFile(content);
    const parsed = charter.parseCharterToml(content) catch {
        common.printStr("Error: Invalid Charter TOML.\n");
        return;
    };
    savePendingCharterFile(content);
    const lo = @import("../ssh.zig").parseIpv4("127.0.0.1") orelse 0;
    postProposalToBoard(alloc, lo, port, content, &parsed) catch |e| {
        common.printApiError("Post Charter proposal to local board", e);
        return;
    };
    if (json_f) {
        common.printFmt(
            "{{\"status\":\"disseminated\",\"version\":{d}," ++
                "\"sha256\":\"{s}\"}}\n",
            .{ parsed.version, &parsed.sha256_hex },
        );
    } else {
        common.printFmt(
            "✓ Disseminated Charter v{d} (SHA-256: {s}) on local board.\n",
            .{ parsed.version, &parsed.sha256_hex },
        );
    }
}

pub fn cmdCharterVote(
    client: *api.DiosixClient,
    args: []const [*:0]const u8,
    arg_start: usize,
    default_file: []const u8,
    json_mode: bool,
) void {
    const alloc = std.heap.page_allocator;
    var file_path: []const u8 = sysconfig.CHARTER_PENDING_PATH;
    var has_file = false;
    var mode: VoteMode = .auto;
    var port: u16 = sysconfig.DEFAULT_BOARD_PORT;
    var json_f = json_mode;
    var i: usize = arg_start;
    while (i < args.len) : (i += 1) {
        const s = std.mem.span(args[i]);
        const opt = std.meta.stringToEnum(VoteOption, s) orelse continue;
        switch (opt) {
            .@"--file", .@"-f" => if (i + 1 < args.len) {
                i += 1;
                file_path = std.mem.span(args[i]);
                has_file = true;
            },
            .@"--approve", .@"-a" => mode = .approve,
            .@"--reject" => mode = .reject,
            .@"--auto" => mode = .auto,
            .@"--port", .@"-p" => if (i + 1 < args.len) {
                i += 1;
                port = std.fmt.parseInt(u16, std.mem.span(args[i]), 10) catch
                    sysconfig.DEFAULT_BOARD_PORT;
            },
            .@"--json", .@"-j" => json_f = true,
        }
    }
    const read_path = if (has_file)
        file_path
    else
        sysconfig.CHARTER_PENDING_PATH;
    const raw = common.readBinaryFile(
        read_path,
        common.MAX_MANIFEST_SIZE,
    ) catch (if (!has_file)
        common.readBinaryFile(default_file, common.MAX_MANIFEST_SIZE)
    else
        error.FileNotFound) catch |e| {
        common.printApiError("Read Charter proposal", e);
        return;
    };
    defer common.unmapBinaryFile(raw);

    const out = castMissionVote(alloc, client, raw, mode, port) catch |e| {
        common.printApiError("Cast M-mode quota-stake vote", e);
        return;
    };
    const dec_s = if (out.decision == .approve) "approve" else "reject";
    if (json_f) {
        common.printFmt(
            "{{\"decision\":\"{s}\",\"allowed\":{},\"version\":{d}," ++
                "\"caller_stake_pages\":{d},\"approved_stake_pages\":{d}," ++
                "\"eligible_stake_pages\":{d},\"reason\":\"{s}\"}}\n",
            .{
                dec_s,
                out.check.allowed,
                out.parsed.version,
                out.vote_args.caller_stake_pages,
                out.vote_args.approved_stake_pages,
                out.vote_args.eligible_stake_pages,
                out.check.reason,
            },
        );
    } else {
        common.printFmt(
            "✓ Voted {s} for Charter v{d} (stake: {d} pages, " ++
                "tally: {d}/{d} approved; {s}).\n",
            .{
                dec_s,
                out.parsed.version,
                out.vote_args.caller_stake_pages,
                out.vote_args.approved_stake_pages,
                out.vote_args.eligible_stake_pages,
                out.check.reason,
            },
        );
    }
}

test "charter/ops: VoteMode and VoteOption enum dispatch" {
    std.testing.refAllDecls(@This());
    try std.testing.expectEqual(
        VoteMode.reject,
        std.meta.stringToEnum(VoteMode, "reject").?,
    );
    try std.testing.expectEqual(
        VoteOption.@"--approve",
        std.meta.stringToEnum(VoteOption, "--approve").?,
    );
}
