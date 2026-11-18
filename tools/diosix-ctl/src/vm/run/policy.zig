// Post-Spawn VM Resource Flags, Agent Mode, and LLM Budget Policies.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const api = @import("../../api.zig");
const agent_admin = @import("../../agent/admin.zig");
const agent_cfg = @import("../../agent/config.zig");
const ledger = @import("../../agent/ledger.zig");
const common = @import("../../common.zig");
const fdt_guest = @import("../fdt_guest.zig");
const net = @import("../../net.zig");
const net_http = @import("../../net/http.zig");
const pkg_policy = @import("../../pkg/policy.zig");
const run_opts = @import("../run_opts.zig");
const sysconfig = @import("../../sysconfig.zig");
const vm_stage = @import("../stage.zig");

pub fn validateRunPolicyOpts(opts: run_opts.ParsedRunOptions) bool {
    if (opts.tokens_str) |ts| {
        _ = ledger.parseTokenAmount(ts) catch {
            common.printStr("Error: Invalid '--tokens' amount.\n");
            return false;
        };
    }
    if (opts.budget_usd_str) |bs| {
        _ = ledger.parseUsdToMicros(bs) catch {
            common.printStr("Error: Invalid '--budget-usd' amount.\n");
            return false;
        };
    }
    if (opts.max_thinking_str) |mt| {
        if (agent_cfg.parseThinkingLevel(mt) == null) {
            common.printStr(
                "Error: '--max-thinking' must be minimal|low|medium|high.\n",
            );
            return false;
        }
    }
    if (opts.agent_mode_str) |am| {
        if (std.meta.stringToEnum(agent_cfg.AgentUserMode, am) == null) {
            common.printStr(
                "Error: '--agent-mode' must be off|root|sudoer|non-sudoer.\n",
            );
            return false;
        }
    }
    return true;
}

pub fn buildRunFlags(
    opts: run_opts.ParsedRunOptions,
    eff_net_mode: net.NetMode,
    upstream_cid: usize,
) usize {
    var run_flags: usize = if (opts.trusted) api.RunFlags.TRUSTED else 0;
    if (opts.is_steward) run_flags |= api.RunFlags.STEWARD;
    if (opts.is_standby_root) run_flags |= api.RunFlags.STANDBY_ROOT;
    if (opts.is_confidential) run_flags |= api.RunFlags.CONFIDENTIAL;
    if (opts.is_leaf) run_flags |= api.RunFlags.LEAF_NO_CHILDREN;
    if (opts.delegate_stake or opts.is_steward) {
        run_flags |= api.RunFlags.DELEGATE_STAKE;
    }
    if (eff_net_mode == .none) run_flags |= api.RunFlags.NET_ISOLATED;
    if (upstream_cid > 0) {
        run_flags |= (upstream_cid & api.RunFlags.NET_UPSTREAM_MASK) <<
            api.RunFlags.NET_UPSTREAM_SHIFT;
    }
    return run_flags;
}

pub fn computeDepthQuota(opts: run_opts.ParsedRunOptions) u64 {
    if (opts.is_leaf) return api.QUOTA_ZERO_SENTINEL;
    if (opts.max_depth) |d| {
        return if (d == 0) api.QUOTA_ZERO_SENTINEL else @intCast(d);
    }
    return 0;
}

pub fn computeDescendantQuota(opts: run_opts.ParsedRunOptions) u64 {
    if (opts.is_leaf) return api.QUOTA_ZERO_SENTINEL;
    if (opts.max_children) |c| {
        return if (c == 0) api.QUOTA_ZERO_SENTINEL else @intCast(c);
    }
    return 0;
}

fn upsertManifestDirective(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    child_cid: usize,
    prefix: []const u8,
    directive_line: []const u8,
) void {
    const buf = allocator.alloc(u8, common.MAX_MANIFEST_SIZE) catch return;
    defer allocator.free(buf);
    const mlen = client.getManifest(child_cid, buf) catch return;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var lines = std.mem.splitScalar(u8, buf[0..mlen], '\n');
    while (lines.next()) |raw| {
        const line = common.trimWhitespace(raw);
        if (std.mem.startsWith(u8, line, prefix)) continue;
        if (raw.len == 0 and out.items.len == 0) continue;
        out.appendSlice(allocator, raw) catch return;
        out.append(allocator, '\n') catch return;
    }
    out.appendSlice(allocator, directive_line) catch return;
    client.setManifest(child_cid, out.items) catch {};
}

fn appendAgentModeDirective(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    child_cid: usize,
    mode_str: []const u8,
) void {
    const hdr = allocator.print(
        "# diosix-agent-mode: {s}\n",
        .{mode_str},
    ) catch return;
    defer allocator.free(hdr);
    upsertManifestDirective(
        allocator,
        client,
        child_cid,
        "# diosix-agent-mode:",
        hdr,
    );
}

pub fn applyChildPoliciesAndQuotas(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    child_cid: usize,
    opts: run_opts.ParsedRunOptions,
    final_ip: []const u8,
    eff_net_mode: net.NetMode,
    upstream_cid: usize,
) !void {
    const inject_key = !opts.is_confidential and !opts.is_steward;
    vm_stage.stageChildVmManifest(
        allocator,
        client,
        child_cid,
        opts.vm_name.?,
        opts.domain_name,
        opts.manifest_path,
        inject_key,
    );
    net.applyVmNetConfig(
        allocator,
        client,
        child_cid,
        final_ip,
        eff_net_mode,
        upstream_cid,
    );
    pkg_policy.applyRunPackagesPolicy(
        allocator,
        client,
        child_cid,
        opts.packages_str,
    );

    ledger.resetChildQuota(allocator, child_cid, null);
    if (opts.tokens_str != null or
        opts.budget_usd_str != null or
        opts.max_thinking_str != null)
    {
        var req = ledger.ChildGrantReq{};
        if (opts.tokens_str) |ts| req.tokens = try ledger.parseTokenAmount(ts);
        if (opts.budget_usd_str) |bs| {
            req.cost_micros = try ledger.parseUsdToMicros(bs);
        }
        if (opts.max_thinking_str) |mt| {
            req.max_thinking = agent_cfg.parseThinkingLevel(mt);
        }
        if (req.tokens != null and req.cost_micros == null) {
            req.cost_micros = .{
                .value = @max(@as(u64, 50_000), req.tokens.?.value *| 10),
            };
        } else if (req.cost_micros != null and req.tokens == null) {
            req.tokens = .{ .value = 1_000_000 };
        }
        const has_p = net_http.isHasParent(client);
        var cfg = agent_cfg.loadAgentConfig(allocator, has_p);
        defer cfg.deinit();
        const entry = try ledger.grantChildQuota(
            allocator,
            client,
            &cfg,
            has_p,
            child_cid,
            req,
            null,
        );
        agent_admin.updateManifestLlmDirectives(
            allocator,
            client,
            child_cid,
            entry,
        );
    }

    if (opts.agent_mode_str) |am| {
        appendAgentModeDirective(allocator, client, child_cid, am);
    }
    if (opts.is_leaf) {
        upsertManifestDirective(
            allocator,
            client,
            child_cid,
            pkg_policy.LEAF_POLICY_PREFIX,
            "# diosix-leaf: true\n",
        );
    }
}

pub fn buildIpAutoconfig(
    allocator: std.mem.Allocator,
    is_shim_boot: bool,
    eff_net_mode: net.NetMode,
    final_ip: []const u8,
    upstream_cid: usize,
    sys_cfg: sysconfig.SystemConfig,
    vm_name: []const u8,
) ?[]u8 {
    if (!is_shim_boot or eff_net_mode == .none or final_ip.len == 0) {
        return null;
    }
    const gw_host: usize = if (upstream_cid >= common.CID_FIRST_CHILD)
        upstream_cid
    else
        1;
    const resolv_raw = common.readBinaryFile(
        sysconfig.RESOLV_CONF_PATH,
        4096,
    ) catch &[_]u8{};
    defer common.unmapBinaryFile(resolv_raw);
    const dns_sfx = fdt_guest.formatDnsSuffixFromResolv(
        allocator,
        resolv_raw,
    ) catch null;
    defer if (dns_sfx) |d| allocator.free(d);
    return allocator.print(
        "{s}::{s}{d}:255.255.255.0:{s}:eth0:off{s}",
        .{
            final_ip,
            sys_cfg.subnetPrefix(),
            gw_host,
            vm_name,
            dns_sfx orelse "",
        },
    ) catch null;
}

test "vm/run/policy: leaf flags and zero sentinel computation" {
    std.testing.refAllDecls(@This());
    const t = std.testing;
    const o = run_opts.ParsedRunOptions{ .is_leaf = true, .max_children = 0 };
    const fl = buildRunFlags(o, .local, 0);
    try t.expect((fl & api.RunFlags.LEAF_NO_CHILDREN) != 0);
    try t.expect((fl & api.RunFlags.DELEGATE_STAKE) == 0);
    try t.expectEqual(api.QUOTA_ZERO_SENTINEL, computeDepthQuota(o));
    try t.expectEqual(api.QUOTA_ZERO_SENTINEL, computeDescendantQuota(o));
    try t.expect(validateRunPolicyOpts(o));
}
