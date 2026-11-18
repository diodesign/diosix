// Autonomous VM-Organizing Board Task & Child Alert Execution Loop.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const api = @import("../api.zig");
const cfg_mod = @import("config.zig");
const common = @import("../common.zig");
const gateway = @import("gateway.zig");
const net_http = @import("../net/http.zig");
const ssh = @import("../ssh.zig");
const sysconfig = @import("../sysconfig.zig");
const vote = @import("loop/vote.zig");
pub const actions = @import("autonomy/actions.zig");
pub const telemetry = @import("autonomy/telemetry.zig");

pub const hasCompletedSeq = telemetry.hasCompletedSeq;
pub const recordCompletedSeq = telemetry.recordCompletedSeq;
pub const isSafeAgentWritePath = actions.isSafeAgentWritePath;

const MAX_BOARD_LIST_BYTES: usize = 512 * 1024;
const MAX_ACTIONS_PER_TASK: usize = 8;
const BoardEntryJson = telemetry.BoardEntryJson;
const TaskPlanJson = actions.TaskPlanJson;

pub fn extractJsonObject(raw: []const u8) []const u8 {
    const start = std.mem.indexOfScalar(u8, raw, '{') orelse return raw;
    const end = std.mem.lastIndexOfScalar(u8, raw, '}') orelse return raw;
    if (end < start) return raw;
    return raw[start .. end + 1];
}

fn postTaskReceipt(
    allocator: std.mem.Allocator,
    board_ip: u32,
    receipt_kind: []const u8,
    task_seq: u64,
    ok_cnt: usize,
    fail_cnt: usize,
    summary: []const u8,
) void {
    const status_s: []const u8 = if (fail_cnt == 0) "completed" else "failed";
    const s_esc = common.escapeJsonAlloc(allocator, summary) catch return;
    defer allocator.free(s_esc);
    const body = allocator.print(
        "{{\"kind\":\"{s}\",\"task_seq\":{d},\"status\":\"{s}\"," ++
            "\"actions_ok\":{d},\"summary\":\"{s}\"}}",
        .{ receipt_kind, task_seq, status_s, ok_cnt, s_esc },
    ) catch return;
    defer allocator.free(body);
    const b_esc = common.escapeJsonAlloc(allocator, body) catch return;
    defer allocator.free(b_esc);
    const req = allocator.print(
        "{{\"topic\":\"task_status\",\"target_cid\":0,\"body\":\"{s}\"}}",
        .{b_esc},
    ) catch return;
    defer allocator.free(req);
    const resp = net_http.httpClientRequest(
        allocator,
        board_ip,
        sysconfig.DEFAULT_BOARD_PORT,
        "POST",
        "/v1/messages",
        "application/json",
        req,
        64 * 1024,
    ) catch return;
    resp.deinit(allocator);
}

fn executePlanPrompt(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    board_ip: u32,
    seq: u64,
    prompt: []const u8,
    req_thinking: ?cfg_mod.ThinkingLevel,
    receipt_kind: []const u8,
    report: *vote.StepReport,
) bool {
    const obs = telemetry.collectNodeObservationAlloc(allocator, client) catch
        null;
    defer if (obs) |o| allocator.free(o);
    const sys_p = allocator.print(
        "Return JSON: {{\"summary\":\"...\"," ++
            "\"actions\":[{{\"action\":\"write_file|install_pkg|" ++
            "spawn_vm|stop_vm|run_cmd|ssh_child|grant_quota\",...}}]}}\n{s}",
        .{obs orelse ""},
    ) catch return false;
    defer allocator.free(sys_p);

    const gw_res = gateway.queryLocalGatewayOrDirect(
        allocator,
        client,
        sys_p,
        prompt,
        req_thinking,
        512,
        "json",
    ) catch return false;
    defer gw_res.deinit(allocator);

    const plan = std.json.parseFromSlice(
        TaskPlanJson,
        allocator,
        extractJsonObject(gw_res.answer),
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    ) catch return false;
    defer plan.deinit();

    var ok_cnt: usize = 0;
    var fail_cnt: usize = 0;
    const limit: usize = @min(plan.value.actions.len, MAX_ACTIONS_PER_TASK);
    for (plan.value.actions[0..limit]) |act| {
        if (actions.executeAction(allocator, client, act)) {
            ok_cnt += 1;
        } else {
            fail_cnt += 1;
        }
    }
    postTaskReceipt(
        allocator,
        board_ip,
        receipt_kind,
        seq,
        ok_cnt,
        fail_cnt,
        plan.value.summary,
    );
    report.tasks_completed += 1;
    return true;
}

fn processChildAlerts(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    report: *vote.StepReport,
) void {
    const lo = ssh.parseIpv4("127.0.0.1") orelse return;
    const since = telemetry.readLastSeq(null);
    const alerts = telemetry.fetchUnreadChildAlertsAlloc(allocator, since) catch
        return;
    defer alerts.deinit();

    var max_seq = since;
    for (alerts.value) |m| {
        if (m.seq > max_seq) max_seq = m.seq;
        if (m.author_cid < common.CID_FIRST_CHILD) continue;
        const prompt = allocator.print("ALERT_REPAIR: {s}", .{m.body}) catch
            continue;
        defer allocator.free(prompt);
        _ = executePlanPrompt(
            allocator,
            client,
            lo,
            m.seq,
            prompt,
            .low,
            "repair_receipt",
            report,
        );
    }
    if (max_seq > since) telemetry.writeLastSeq(allocator, max_seq, null);
}

pub fn processBoardTasks(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    report: *vote.StepReport,
) void {
    const has_p = net_http.isHasParent(client);
    const board_ip = if (has_p)
        net_http.resolveParentIpv4(client)
    else
        (ssh.parseIpv4("127.0.0.1") orelse return);

    const resp = net_http.httpClientRequest(
        allocator,
        board_ip,
        sysconfig.DEFAULT_BOARD_PORT,
        "GET",
        "/v1/messages?topic=task",
        null,
        "",
        MAX_BOARD_LIST_BYTES,
    ) catch {
        processChildAlerts(allocator, client, report);
        return;
    };
    defer resp.deinit(allocator);
    if (resp.status < 400) {
        if (std.json.parseFromSlice(
            []const BoardEntryJson,
            allocator,
            resp.body,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        )) |msgs| {
            defer msgs.deinit();
            for (msgs.value) |m| {
                if (!has_p and m.target_cid >= common.CID_FIRST_CHILD) continue;
                if (hasCompletedSeq(m.seq, null)) continue;
                const prompt = allocator.print(
                    "TASK_PLAN: {s}",
                    .{m.body},
                ) catch continue;
                defer allocator.free(prompt);
                if (executePlanPrompt(
                    allocator,
                    client,
                    board_ip,
                    m.seq,
                    prompt,
                    null,
                    "task_receipt",
                    report,
                )) {
                    recordCompletedSeq(allocator, m.seq, null);
                }
            }
        } else |_| {}
    }

    processChildAlerts(allocator, client, report);
}

test "agent/autonomy: strips markdown JSON fences and persists task seqs" {
    _ = actions;
    _ = telemetry;
    std.testing.refAllDecls(@This());
    const t = std.testing;
    try t.expectEqualStrings(
        "{\"a\":1}",
        extractJsonObject("```json\n{\"a\":1}\n```"),
    );

    const seq_p = ".zig-cache/test-done-seqs.txt";
    var pz: [common.MAX_PATH_LEN]u8 = undefined;
    const pzs = common.toPathZ(seq_p, &pz).?;
    _ = linux.unlink(pzs.ptr);
    defer _ = linux.unlink(pzs.ptr);
    recordCompletedSeq(t.allocator, 12, seq_p);
    try t.expect(hasCompletedSeq(12, seq_p));
    try t.expect(!hasCompletedSeq(1, seq_p));
}
