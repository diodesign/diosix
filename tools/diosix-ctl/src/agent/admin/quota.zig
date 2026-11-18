// Agent Gateway Credential, Quota Inspection, and Child Budget Grant Commands.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const api = @import("../../api.zig");
const cfg_mod = @import("../config.zig");
const common = @import("../../common.zig");
const gateway = @import("../gateway.zig");
const ledger = @import("../ledger.zig");
const net_http = @import("../../net/http.zig");
const pkg = @import("../../pkg.zig");
const ssh = @import("../../ssh.zig");
const sysconfig = @import("../../sysconfig.zig");

const KeyOption = enum {
    @"--provider",
    @"--key",
    @"-k",
    @"--endpoint",
    @"-e",
    @"--json",
    @"-j",
};

const GrantOption = enum {
    @"--tokens",
    @"--budget-usd",
    @"--max-thinking",
    @"--rpm",
    @"--tpm",
    @"--json",
    @"-j",
};

pub fn failExit() void {
    if (!@import("builtin").is_test) std.process.exit(1);
}

pub fn takeArg(args: []const [*:0]const u8, idx: *usize) ?[]const u8 {
    if (idx.* + 1 >= args.len) return null;
    idx.* += 1;
    return std.mem.span(args[idx.*]);
}

pub fn cmdSetKey(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    args: []const [*:0]const u8,
    json_f: bool,
) void {
    if (net_http.isHasParent(client)) {
        common.printStr(
            "Error: Child VMs cannot store upstream LLM keys; query parent.\n",
        );
        return failExit();
    }
    var prov_opt: ?cfg_mod.AgentProvider = null;
    var key_val: []const u8 = "";
    var endpoint_opt: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const s = std.mem.span(args[i]);
        const opt = std.meta.stringToEnum(KeyOption, s) orelse continue;
        switch (opt) {
            .@"--provider" => {
                const v = takeArg(args, &i) orelse return failExit();
                prov_opt = std.meta.stringToEnum(cfg_mod.AgentProvider, v);
            },
            .@"--key", .@"-k" => key_val = takeArg(args, &i) orelse "",
            .@"--endpoint", .@"-e" => endpoint_opt = takeArg(args, &i),
            .@"--json", .@"-j" => {},
        }
    }
    const prov = prov_opt orelse {
        common.printStr(
            "Usage: dsx agent set-key --provider <openrouter|opencode|" ++
                "local|policy> [--key <secret>] [--endpoint <url>]\n",
        );
        return failExit();
    };
    if (prov == .parent or prov == .auto) {
        common.printStr("Error: Invalid upstream secret provider.\n");
        return failExit();
    }
    cfg_mod.writeSecretKeyFile(
        allocator,
        prov,
        key_val,
        endpoint_opt,
    ) catch |e| {
        common.printApiError("Store gateway API secret", e);
        return failExit();
    };
    if (json_f) {
        common.printFmt(
            "{{\"status\":\"saved\",\"provider\":\"{s}\",\"path\":\"{s}\"}}\n",
            .{ @tagName(prov), sysconfig.LLM_SECRET_KEY_PATH },
        );
    } else {
        common.printFmt(
            "✓ Saved root gateway provider '{s}' credentials ({s}).\n",
            .{ @tagName(prov), sysconfig.LLM_SECRET_KEY_PATH },
        );
    }
}

fn querySelfQuotaViaLocalHttp(
    allocator: std.mem.Allocator,
    port: u16,
) ?ledger.QuotaView {
    const lo = ssh.parseIpv4("127.0.0.1") orelse return null;
    const resp = net_http.httpClientRequest(
        allocator,
        lo,
        port,
        "GET",
        "/v1/quota",
        null,
        "",
        64 * 1024,
    ) catch return null;
    defer resp.deinit(allocator);
    if (resp.status >= 400) return null;
    const QJson = struct {
        cid: usize = 0,
        max_tokens: u64 = 0,
        used_tokens: u64 = 0,
        reserved_tokens: u64 = 0,
        delegated_tokens: u64 = 0,
        remaining_tokens: u64 = 0,
        max_cost_micros: u64 = 0,
        used_cost_micros: u64 = 0,
        reserved_cost_micros: u64 = 0,
        delegated_cost_micros: u64 = 0,
        remaining_cost_micros: u64 = 0,
        max_thinking: []const u8 = "low",
        rpm_limit: u32 = 0,
        tpm_limit: u32 = 0,
    };
    const p = std.json.parseFromSlice(
        QJson,
        allocator,
        resp.body,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    ) catch return null;
    defer p.deinit();
    const v = p.value;
    return .{
        .cid = v.cid,
        .max_tokens = v.max_tokens,
        .used_tokens = v.used_tokens,
        .reserved_tokens = v.reserved_tokens,
        .delegated_tokens = v.delegated_tokens,
        .remaining_tokens = v.remaining_tokens,
        .max_cost_micros = v.max_cost_micros,
        .used_cost_micros = v.used_cost_micros,
        .reserved_cost_micros = v.reserved_cost_micros,
        .delegated_cost_micros = v.delegated_cost_micros,
        .remaining_cost_micros = v.remaining_cost_micros,
        .max_thinking = cfg_mod.parseThinkingLevel(v.max_thinking) orelse .low,
        .rpm_limit = v.rpm_limit,
        .tpm_limit = v.tpm_limit,
    };
}

pub fn cmdQuota(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    args: []const [*:0]const u8,
    json_f: bool,
) void {
    var target_opt: ?[]const u8 = null;
    for (args[1..]) |a| {
        const s = std.mem.span(a);
        if (!std.mem.startsWith(u8, s, "-") and target_opt == null) {
            target_opt = s;
        }
    }
    var target_cid: usize = common.CID_PARENT;
    if (target_opt) |ts| {
        const parsed = common.parseCid(ts) catch null;
        if (parsed == common.CID_SELF or parsed == common.CID_PARENT) {
            target_cid = common.CID_PARENT;
        } else {
            target_cid = pkg.resolveChildTargetCid(ts) orelse {
                common.printFmt("Error: Unknown target VM '{s}'.\n", .{ts});
                return failExit();
            };
        }
    }

    const has_p = net_http.isHasParent(client);
    var cfg = cfg_mod.loadAgentConfig(allocator, has_p);
    defer cfg.deinit();

    const q = if (target_cid == common.CID_PARENT)
        (querySelfQuotaViaLocalHttp(allocator, cfg.proxy_port) orelse
            (ledger.queryQuotaView(
                allocator,
                client,
                &cfg,
                has_p,
                common.CID_PARENT,
                null,
            ) catch |e| {
                common.printApiError("Query gateway quota", e);
                return failExit();
            }))
    else
        (ledger.queryQuotaView(
            allocator,
            client,
            &cfg,
            has_p,
            target_cid,
            null,
        ) catch |e| {
            common.printApiError("Query gateway quota", e);
            return failExit();
        });

    if (json_f) {
        const js = gateway.formatQuotaViewJsonAlloc(allocator, q) catch return;
        defer allocator.free(js);
        common.printStr(js);
        return;
    }

    common.printFmt(
        "Thinking Gateway Quota (CID {d}):\n" ++
            "  Tokens    : {d} used / {d} max ({d} delegated, {d} rem)\n" ++
            "  Cost uUSD : {d} used / {d} max ({d} delegated, {d} rem)\n" ++
            "  Max Tier  : {s} (rpm={d}, tpm={d})\n",
        .{
            q.cid,
            q.used_tokens,
            q.max_tokens,
            q.delegated_tokens,
            q.remaining_tokens,
            q.used_cost_micros,
            q.max_cost_micros,
            q.delegated_cost_micros,
            q.remaining_cost_micros,
            @tagName(q.max_thinking),
            q.rpm_limit,
            q.tpm_limit,
        },
    );
}

pub fn updateManifestLlmDirectives(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    target_cid: usize,
    entry: ledger.ChildQuotaEntry,
) void {
    const buf = allocator.alloc(u8, common.MAX_MANIFEST_SIZE) catch return;
    defer allocator.free(buf);
    const mlen = client.getManifest(target_cid, buf) catch return;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var lines = std.mem.splitScalar(u8, buf[0..mlen], '\n');
    while (lines.next()) |raw| {
        const line = common.trimWhitespace(raw);
        if (std.mem.startsWith(u8, line, "# diosix-llm-")) continue;
        if (raw.len == 0 and out.items.len == 0) continue;
        out.appendSlice(allocator, raw) catch return;
        out.append(allocator, '\n') catch return;
    }
    const hdr = allocator.print(
        "# diosix-llm-max-tokens: {d}\n" ++
            "# diosix-llm-max-cost-micros: {d}\n" ++
            "# diosix-llm-max-thinking: {s}\n" ++
            "# diosix-llm-rpm: {d}\n" ++
            "# diosix-llm-tpm: {d}\n",
        .{
            entry.max_tokens,
            entry.max_cost_micros,
            entry.max_thinking,
            entry.rpm_limit,
            entry.tpm_limit,
        },
    ) catch return;
    defer allocator.free(hdr);
    out.appendSlice(allocator, hdr) catch return;
    client.setManifest(target_cid, out.items) catch {};
}

pub fn cmdGrant(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    args: []const [*:0]const u8,
    json_f: bool,
) void {
    var target_opt: ?[]const u8 = null;
    var req = ledger.ChildGrantReq{};

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const s = std.mem.span(args[i]);
        if (std.meta.stringToEnum(GrantOption, s)) |opt| {
            switch (opt) {
                .@"--tokens" => {
                    const v = takeArg(args, &i) orelse return failExit();
                    req.tokens = ledger.parseTokenAmount(v) catch {
                        common.printStr("Error: Invalid '--tokens' amount.\n");
                        return failExit();
                    };
                },
                .@"--budget-usd" => {
                    const v = takeArg(args, &i) orelse return failExit();
                    req.cost_micros = ledger.parseUsdToMicros(v) catch {
                        common.printStr("Error: Invalid '--budget-usd'.\n");
                        return failExit();
                    };
                },
                .@"--max-thinking" => {
                    const v = takeArg(args, &i) orelse return failExit();
                    req.max_thinking = cfg_mod.parseThinkingLevel(v) orelse {
                        common.printStr("Error: Invalid '--max-thinking'.\n");
                        return failExit();
                    };
                },
                .@"--rpm" => {
                    const v = takeArg(args, &i) orelse return failExit();
                    req.rpm_limit = std.fmt.parseInt(u32, v, 10) catch
                        return failExit();
                },
                .@"--tpm" => {
                    const v = takeArg(args, &i) orelse return failExit();
                    req.tpm_limit = std.fmt.parseInt(u32, v, 10) catch
                        return failExit();
                },
                .@"--json", .@"-j" => {},
            }
        } else if (!std.mem.startsWith(u8, s, "-") and target_opt == null) {
            target_opt = s;
        }
    }

    const ts = target_opt orelse {
        common.printStr(
            "Usage: dsx agent grant <vm|cid> [--tokens N|+N] " ++
                "[--budget-usd USD|+USD] [--max-thinking T] [--json]\n",
        );
        return failExit();
    };
    const cid = pkg.resolveChildTargetCid(ts) orelse {
        common.printFmt("Error: Unknown child VM '{s}'.\n", .{ts});
        return failExit();
    };

    const has_p = net_http.isHasParent(client);
    var cfg = cfg_mod.loadAgentConfig(allocator, has_p);
    defer cfg.deinit();
    const entry = ledger.grantChildQuota(
        allocator,
        client,
        &cfg,
        has_p,
        cid,
        req,
        null,
    ) catch |e| {
        common.printApiError("Grant child LLM quota", e);
        return failExit();
    };
    updateManifestLlmDirectives(allocator, client, cid, entry);

    if (json_f) {
        common.printFmt(
            "{{\"cid\":{d},\"max_tokens\":{d},\"max_cost_micros\":{d}," ++
                "\"max_thinking\":\"{s}\",\"rpm_limit\":{d}," ++
                "\"tpm_limit\":{d}}}\n",
            .{
                entry.cid,
                entry.max_tokens,
                entry.max_cost_micros,
                entry.max_thinking,
                entry.rpm_limit,
                entry.tpm_limit,
            },
        );
    } else {
        common.printFmt(
            "✓ Updated CID {d}: tokens={d}, cost_micros={d}, tier={s}.\n",
            .{
                entry.cid,
                entry.max_tokens,
                entry.max_cost_micros,
                entry.max_thinking,
            },
        );
    }
}

test "agent/admin/quota: option enums compile cleanly" {
    std.testing.refAllDecls(@This());
    try std.testing.expectEqual(
        GrantOption.@"--budget-usd",
        std.meta.stringToEnum(GrantOption, "--budget-usd").?,
    );
}
