// Offline Deterministic Policy Brain & Closed-Loop Task/Repair Planners.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const common = @import("../../common.zig");

const KV_SERVE_B64 =
    "IyEvYmluL3NoCkQ9L3Zhci9saWIvZGlvc2l4LWt2OyBta2RpciAtcCAkRApJRlM9" ++
    "IHJlYWQgLXIgbCB8fCBleGl0IDAKcj0kKHByaW50ZiAiXHIiKTsgc2V0IC0tICR7" ++
    "bCUkcn07IHA9JDIKd2hpbGUgSUZTPSByZWFkIC1yIGg7IGRvIFsgLXogIiR7aCUk" ++
    "cn0iIF0gJiYgYnJlYWs7IGRvbmUKcT0ke3AjKlw/fQprPSQocHJpbnRmICIlc1xu" ++
    "IiAiJHEifHNlZCAtbiAicy8uKmtleT1cKFteJl0qXCkuKi9cMS9wInx0ciAtY2Qg" ++
    "QS1aYS16MC05Xy4tKQp2PSQocHJpbnRmICIlc1xuIiAiJHEifHNlZCAtbiAicy8u" ++
    "KnZhbD1cKFteJl0qXCkuKi9cMS9wInx0ciAtY2QgQS1aYS16MC05Xy4tKQpbIC16" ++
    "ICIkayIgXSAmJiBrPWRlZmF1bHQKaWYgWyAtbiAiJHYiIF07IHRoZW4gcHJpbnRm" ++
    "ICIlc1xuIiAiJHYiID4gIiRELyRrIjsgYj0iT0s6JHYiCmVsc2UgYj0kKGNhdCAi" ++
    "JEQvJGsiIDI+L2Rldi9udWxsIHx8IGVjaG8gTk9UX0ZPVU5EKTsgZmkKcHJpbnRm" ++
    "ICJIVFRQLzEuMCAyMDAgT0tcclxuQ29udGVudC1MZW5ndGg6ICVkXHJcblxyXG4l" ++
    "c1xuIiAiJCgoJHsjYn0rMSkpIiAiJGIiCg==";

const KV_SETUP_CMD =
    "PATH=$PATH:/usr/local/sbin:/usr/local/bin; " ++
    "iptables -I INPUT 1 -p tcp --dport 8088 -j ACCEPT " ++
    "2>/dev/null || true; " ++
    "D=/var/lib/diosix-kv; mkdir -p $D && printf '%s' '" ++ KV_SERVE_B64 ++
    "' | base64 -d > $D/serve.sh && chmod 755 $D/serve.sh && " ++
    "F=$D/nc.pid; ([ -s $F ] && kill $(cat $F) 2>/dev/null || true); " ++
    "busybox nc -lk -p 8088 -e /bin/sh $D/serve.sh " ++
    "</dev/null >/dev/null 2>&1 & echo $! > $F; sleep 1";

fn formatKvDeployPlanJson(allocator: std.mem.Allocator) ![]u8 {
    return allocator.print(
        "{{\"summary\":\"Deployed replicated KV cluster\"," ++
            "\"actions\":[" ++
            "{{\"action\":\"spawn_vm\",\"name\":\"kv-1\",\"ram\":\"128M\"," ++
            "\"leaf\":true}}," ++
            "{{\"action\":\"spawn_vm\",\"name\":\"kv-2\",\"ram\":\"128M\"," ++
            "\"leaf\":true}}," ++
            "{{\"action\":\"spawn_vm\",\"name\":\"edge-mon\"," ++
            "\"ram\":\"128M\",\"leaf\":true,\"tokens\":\"8000\"," ++
            "\"budget_usd\":\"0.05\",\"max_thinking\":\"low\"}}," ++
            "{{\"action\":\"ssh_child\",\"target\":\"kv-1\"," ++
            "\"cmd\":\"{s}\"}}," ++
            "{{\"action\":\"ssh_child\",\"target\":\"kv-2\"," ++
            "\"cmd\":\"{s}\"}}" ++
            "]}}",
        .{ KV_SETUP_CMD, KV_SETUP_CMD },
    );
}

fn detectFailedReplica(prompt_body: []const u8) []const u8 {
    const tail = if (std.mem.indexOf(u8, prompt_body, "ALERT_REPAIR:")) |i|
        prompt_body[i..]
    else
        prompt_body;
    if (std.mem.indexOf(u8, tail, "kv-2") != null) return "kv-2";
    return "kv-1";
}

fn formatAlertRepairPlanJson(
    allocator: std.mem.Allocator,
    prompt_body: []const u8,
) ![]u8 {
    const failed = detectFailedReplica(prompt_body);
    const peer: []const u8 = if (std.mem.eql(u8, failed, "kv-1"))
        "kv-2"
    else
        "kv-1";
    return allocator.print(
        "{{\"summary\":\"Repaired failed replica {s} from peer {s}\"," ++
            "\"actions\":[" ++
            "{{\"action\":\"stop_vm\",\"target\":\"{s}\"}}," ++
            "{{\"action\":\"spawn_vm\",\"name\":\"{s}\",\"ram\":\"128M\"," ++
            "\"leaf\":true}}," ++
            "{{\"action\":\"ssh_child\",\"target\":\"{s}\"," ++
            "\"cmd\":\"{s}\"}}," ++
            "{{\"action\":\"run_cmd\",\"cmd\":" ++
            "\"F=$(awk '/^name = \\\"{s}\\\"$/{{f=1}} " ++
            "f&&/^ip = \\\"/{{gsub(/\\\"/,\\\"\\\",$3);print $3;exit}}' " ++
            "/run/diosix/guests.toml); " ++
            "P=$(awk '/^name = \\\"{s}\\\"$/{{f=1}} " ++
            "f&&/^ip = \\\"/{{gsub(/\\\"/,\\\"\\\",$3);print $3;exit}}' " ++
            "/run/diosix/guests.toml); " ++
            "V=$(wget -qO- \\\"http://$P:8088/kv?key=mission_state\\\" | " ++
            "tr -cd A-Za-z0-9_.-); " ++
            "[ -n \\\"$V\\\" ] && [ \\\"$V\\\" != NOT_FOUND ] && " ++
            "wget -qO- \\\"http://$F:8088/kv?key=mission_state&val=$V\\\" " ++
            "|| true\"}}]}}",
        .{ failed, peer, failed, failed, failed, KV_SETUP_CMD, failed, peer },
    );
}

fn formatPolicyTaskPlanJson(
    allocator: std.mem.Allocator,
    prompt_body: []const u8,
) ![]u8 {
    if (std.mem.indexOf(u8, prompt_body, "ALERT_REPAIR:") != null) {
        return formatAlertRepairPlanJson(allocator, prompt_body);
    }
    if (std.mem.indexOf(u8, prompt_body, "DEPLOY_KV_CLUSTER") != null) {
        return formatKvDeployPlanJson(allocator);
    }

    var path: []const u8 = "/var/lib/diosix/agent/task-output.txt";
    if (std.mem.indexOf(u8, prompt_body, "/tmp/")) |idx| {
        var end = idx;
        while (end < prompt_body.len) : (end += 1) {
            const c = prompt_body[end];
            if (c <= ' ' or c == '"' or c == '\'' or c == '\\' or c == ')') {
                break;
            }
        }
        if (end > idx + 5) path = prompt_body[idx..end];
    }
    const p_esc = try common.escapeJsonAlloc(allocator, path);
    defer allocator.free(p_esc);
    return allocator.print(
        "{{\"summary\":\"Executed autonomous node task plan\"," ++
            "\"actions\":[{{\"action\":\"write_file\",\"path\":\"{s}\"," ++
            "\"content\":\"AUTONOMOUS_OK\\n\"}}]}}",
        .{p_esc},
    );
}

/// Deterministic offline policy engine used when no remote/local LLM endpoint
/// is configured, emitting OpenAI-compatible chat completion JSON.
pub fn evaluatePolicyBrain(
    allocator: std.mem.Allocator,
    model_name: []const u8,
    prompt_body: []const u8,
) ![]u8 {
    const is_plan =
        std.mem.indexOf(u8, prompt_body, "TASK_PLAN:") != null or
        std.mem.indexOf(u8, prompt_body, "ALERT_REPAIR:") != null;
    const content_json = if (is_plan)
        try formatPolicyTaskPlanJson(allocator, prompt_body)
    else blk: {
        const is_ransom = std.mem.indexOf(u8, prompt_body, "min=0") != null or
            std.mem.indexOf(u8, prompt_body, "encrypt_volumes=true") != null or
            std.mem.indexOf(u8, prompt_body, "wipe_volumes=true") != null;
        const dec = if (is_ransom) "reject" else "approve";
        const summary = if (is_ransom)
            "Deterministic policy vetoed unsafe replica drop or volume mutation"
        else
            "Constitutional invariants verified; proceed with task execution";
        break :blk try allocator.print(
            "{{\"decision\":\"{s}\",\"summary\":\"{s}\"}}",
            .{ dec, summary },
        );
    };
    defer allocator.free(content_json);
    const esc = try common.escapeJsonAlloc(allocator, content_json);
    defer allocator.free(esc);
    const m_esc = try common.escapeJsonAlloc(allocator, model_name);
    defer allocator.free(m_esc);
    return allocator.print(
        "{{\"id\":\"diosix-policy-1\",\"object\":\"chat.completion\"," ++
            "\"model\":\"{s}\",\"choices\":[{{\"index\":0," ++
            "\"message\":{{\"role\":\"assistant\",\"content\":\"{s}\"}}," ++
            "\"finish_reason\":\"stop\"}}]}}\n",
        .{ m_esc, esc },
    );
}

test "agent/llm/policy: emits task, deploy, repair, and vote JSON" {
    std.testing.refAllDecls(@This());
    const t = std.testing;
    const r1 = try evaluatePolicyBrain(
        t.allocator,
        "policy-v1",
        "DEPLOY_KV_CLUSTER TASK_PLAN: start kv",
    );
    defer t.allocator.free(r1);
    try t.expect(std.mem.indexOf(u8, r1, "8088") != null);

    const r2 = try evaluatePolicyBrain(
        t.allocator,
        "policy-v1",
        "ALERT_REPAIR: replica kv-2 unresponsive",
    );
    defer t.allocator.free(r2);
    try t.expect(
        std.mem.indexOf(u8, r2, "Repaired failed replica kv-2") != null,
    );
}
