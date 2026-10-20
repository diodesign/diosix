// Diosix Constitutional Charter Status, Deploy, Propose & Audit Handlers.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const api = @import("../api.zig");
const charter = @import("../charter.zig");
const cmd_mod = @import("cmd.zig");
const common = @import("../common.zig");

const MAX_MANIFEST_SIZE = common.MAX_MANIFEST_SIZE;
const printStr = common.printStr;
const printFmt = common.printFmt;
const printApiError = common.printApiError;
const readBinaryFile = common.readBinaryFile;
const unmapBinaryFile = common.unmapBinaryFile;

const CharterProposeOption = enum {
    @"--unit",
    @"--count",
    @"--total",
    @"--quorum",
};

pub fn cmdCharterStatus(
    client: *api.DiosixClient,
    file_path: []const u8,
    json_mode: bool,
) void {
    const sys_cfg = common.loadRuntimeSystemConfig();
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
    var hv_hash_hex: [charter.SHA256_HEX_LEN]u8 = @splat('0');
    var hv_ratified_mask: u64 = 0;
    var hv_failover_epoch: u64 = 0;
    if (client.getCharter()) |hv_c| {
        hv_sealed = hv_c.is_sealed != 0;
        _ = common.bytesToHex(&hv_c.charter_hash, &hv_hash_hex);
        hv_ratified_mask = hv_c.ratified_mask;
        hv_failover_epoch = hv_c.failover_epoch;
    } else |_| {}

    if (json_mode) {
        const allocator = std.heap.page_allocator;
        const safe_file = common.escapeJsonAlloc(allocator, file_path) catch
            return;
        defer allocator.free(safe_file);
        const safe_id = common.escapeJsonAlloc(allocator, parsed.id()) catch
            return;
        defer allocator.free(safe_id);

        const json_fmt =
            "{{\"file\":\"{s}\",\"file_loaded\":{s},\"id\":\"{s}\"," ++
            "\"version\":{d},\"file_sha256\":\"{s}\"," ++
            "\"mmode_sealed\":{s},\"mmode_sha256\":\"{s}\"," ++
            "\"quorum_required\":{d},\"quorum_total\":{d}," ++
            "\"min_stewards\":{d},\"standby_replicas\":{d}," ++
            "\"unit_count\":{d},\"ratified_mask\":{d}," ++
            "\"failover_epoch\":{d}}}\n";
        printFmt(json_fmt, .{
            safe_file,               if (file_loaded) "true" else "false",
            safe_id,                 parsed.version,
            &parsed.sha256_hex,      if (hv_sealed) "true" else "false",
            &hv_hash_hex,            parsed.quorum_required,
            parsed.quorum_total,     parsed.min_stewards,
            parsed.standby_replicas, parsed.unit_count,
            hv_ratified_mask,        hv_failover_epoch,
        });
    } else {
        const seal_str = if (hv_sealed)
            "sealed in M-mode"
        else
            "unsealed (pending deploy)";
        const load_str = if (file_loaded) "loaded" else "defaults";
        const max_term = parsed.max_simultaneous_unit_termination_pct;
        printFmt(
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
            file_path,                     load_str,
            sys_cfg.constitutionDocPath(), parsed.id(),
            parsed.version,                &parsed.sha256_hex,
            seal_str,                      parsed.quorum_required,
            parsed.quorum_total,           parsed.min_stewards,
            parsed.standby_replicas,       hv_failover_epoch,
            parsed.unit_count,             max_term,
        });
    }
}

pub fn cmdCharterDeploy(
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
    if (json_mode) {
        const allocator = std.heap.page_allocator;
        const safe_id = common.escapeJsonAlloc(allocator, parsed.id()) catch
            return;
        defer allocator.free(safe_id);
        printFmt(
            "{{\"status\":\"sealed\",\"id\":\"{s}\",\"sha256\":\"{s}\"," ++
                "\"quorum_required\":{d},\"quorum_total\":{d}}}\n",
            .{
                safe_id,                &parsed.sha256_hex,
                parsed.quorum_required, parsed.quorum_total,
            },
        );
    } else {
        printFmt(
            "✓ Constitutional Charter '{s}' sealed in M-mode " ++
                "(SHA-256: {s}, quorum: {d}-of-{d}).\n",
            .{
                parsed.id(),            &parsed.sha256_hex,
                parsed.quorum_required, parsed.quorum_total,
            },
        );
    }
}

pub fn cmdCharterPropose(
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
    const action = cmd_mod.parseProposalAction(action_str) orelse {
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
    const mark = if (res.allowed) "✓" else "✗";
    const al_str = if (res.allowed) "true" else "false";
    const rq_str = if (res.requires_quorum) "true" else "false";
    if (json_mode) {
        const allocator = std.heap.page_allocator;
        const safe_act = common.escapeJsonAlloc(allocator, action_str) catch
            return;
        defer allocator.free(safe_act);
        printFmt(
            "{{\"action\":\"{s}\",\"allowed\":{s}," ++
                "\"requires_quorum\":{s},\"reason\":\"{s}\"}}\n",
            .{ safe_act, al_str, rq_str, res.reason },
        );
    } else {
        printFmt(
            "{s} Proposal '{s}': {s}\n",
            .{ mark, action_str, res.reason },
        );
    }
}

pub fn cmdCharterAudit(
    client: *api.DiosixClient,
    file_path: []const u8,
    json_mode: bool,
) void {
    var file_digest: [charter.SHA256_DIGEST_LEN]u8 = @splat(0);
    var file_hex: [charter.SHA256_HEX_LEN]u8 = @splat('0');
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

    if (json_mode) {
        const jfmt =
            "{{\"charter_file_present\":{s},\"mmode_sealed\":{s}," ++
            "\"sha256_verified\":{s}}}\n";
        printFmt(jfmt, .{
            if (file_ok) "true" else "false",
            if (mmode_sealed) "true" else "false",
            if (hash_matches) "true" else "false",
        });
    } else {
        const match_str = if (hash_matches)
            "verified"
        else
            "unverified (seal with 'dsx charter deploy')";
        printFmt(
            \\=== Constitutional Audit ===
            \\  Charter file present : {s}
            \\  M-mode Charter sealed: {s}
            \\  SHA-256 hash match   : {s}
            \\
        , .{
            if (file_ok) "yes" else "no",
            if (mmode_sealed) "yes" else "no",
            match_str,
        });
    }
}

test "charter/status: option enum parses propose flags" {
    std.testing.refAllDecls(@This());
    try std.testing.expectEqual(
        CharterProposeOption.@"--quorum",
        std.meta.stringToEnum(CharterProposeOption, "--quorum").?,
    );
}
