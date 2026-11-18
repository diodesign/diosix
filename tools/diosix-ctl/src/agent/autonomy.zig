// Autonomous VM-Organizing Board Task Execution Loop (`topic=task`).
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const api = @import("../api.zig");
const common = @import("../common.zig");
const gateway = @import("gateway.zig");
const net_http = @import("../net/http.zig");
const pkg_policy = @import("../pkg/policy.zig");
const ssh = @import("../ssh.zig");
const sysconfig = @import("../sysconfig.zig");
const vote = @import("loop/vote.zig");

const MAX_DONE_BYTES: usize = 64 * 1024;
const MAX_BOARD_LIST_BYTES: usize = 512 * 1024;
const MAX_ACTIONS_PER_TASK: usize = 4;

const ActionKind = enum {
    write_file,
    install_pkg,
    spawn_vm,
    stop_vm,
    run_cmd,
    report_board,
};

const BoardEntryJson = struct {
    seq: u64 = 0,
    author_cid: usize = 0,
    target_cid: usize = 0,
    topic: []const u8 = "",
    body: []const u8 = "",
};

const TaskActionJson = struct {
    action: []const u8 = "",
    op: []const u8 = "",
    path: []const u8 = "",
    content: []const u8 = "",
    package: []const u8 = "",
    pkg: []const u8 = "",
    name: []const u8 = "",
    image: []const u8 = "",
    ram: []const u8 = "192M",
    target: []const u8 = "",
    cmd: []const u8 = "",
    delegate_stake: bool = false,
};

const TaskPlanJson = struct {
    summary: []const u8 = "",
    actions: []const TaskActionJson = &.{},
};

pub fn hasCompletedSeq(seq: u64, custom_path: ?[]const u8) bool {
    const p = custom_path orelse sysconfig.AGENT_DONE_TASKS_PATH;
    const raw = common.readBinaryFile(p, MAX_DONE_BYTES) catch return false;
    defer common.unmapBinaryFile(raw);
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |raw_l| {
        const line = common.trimWhitespace(raw_l);
        if (line.len == 0) continue;
        const parsed = std.fmt.parseInt(u64, line, 10) catch continue;
        if (parsed == seq) return true;
    }
    return false;
}

pub fn recordCompletedSeq(
    allocator: std.mem.Allocator,
    seq: u64,
    custom_path: ?[]const u8,
) void {
    const p = custom_path orelse sysconfig.AGENT_DONE_TASKS_PATH;
    if (hasCompletedSeq(seq, p)) return;
    net_http.ensureParentDir(p);
    const old = common.readBinaryFile(p, MAX_DONE_BYTES) catch null;
    defer if (old) |o| common.unmapBinaryFile(o);
    const prev = if (old) |o|
        (if (o.len > MAX_DONE_BYTES / 2)
            o[o.len - MAX_DONE_BYTES / 2 ..]
        else
            o)
    else
        "";
    const next = allocator.print("{s}{d}\n", .{ prev, seq }) catch return;
    defer allocator.free(next);
    common.writeFile(p, next) catch {};
}

pub fn isSafeAgentWritePath(path: []const u8) bool {
    if (path.len == 0 or path.len >= common.MAX_PATH_LEN) return false;
    if (std.mem.indexOf(u8, path, "..") != null) return false;
    const w_pfx = sysconfig.AGENT_WORK_DIR ++ "/";
    if (std.mem.startsWith(u8, path, w_pfx) and path.len > w_pfx.len) {
        return true;
    }
    if (std.mem.startsWith(u8, path, sysconfig.TMP_SLASH_PREFIX) and
        path.len > sysconfig.TMP_SLASH_PREFIX.len)
    {
        return true;
    }
    return false;
}

fn resolveDoasPrefix() ?[*:0]const u8 {
    if (linux.geteuid() == 0) return null;
    if (common.fileExistsPath("/usr/bin/doas")) return "/usr/bin/doas";
    return null;
}

fn resolveDsxBin() [:0]const u8 {
    const cands = [_][:0]const u8{
        "/usr/sbin/dsx",
        "/usr/bin/dsx",
        "/usr/sbin/diosix-ctl",
    };
    return sysconfig.resolveFirstBin(&cands);
}

fn runWriteFile(a: TaskActionJson) bool {
    if (!isSafeAgentWritePath(a.path)) return false;
    net_http.ensureParentDir(a.path);
    common.writeFile(a.path, a.content) catch return false;
    return true;
}

fn runInstallPkg(allocator: std.mem.Allocator, a: TaskActionJson) bool {
    const pkg_name = if (a.package.len > 0) a.package else a.pkg;
    if (!pkg_policy.isValidPkgName(pkg_name)) return false;
    const pz = allocator.printSentinel("{s}", .{pkg_name}, 0) catch
        return false;
    defer allocator.free(pz);
    if (resolveDoasPrefix()) |dp| {
        const argv: [*:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{
            dp, "/sbin/apk", "add", "--no-cache", pz.ptr, null,
        };
        return vote.spawnLoggedSubprocess(argv) == 0;
    }
    const argv: [*:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{
        "/sbin/apk", "add", "--no-cache", pz.ptr, null,
    };
    return vote.spawnLoggedSubprocess(argv) == 0;
}

fn runSpawnVm(allocator: std.mem.Allocator, a: TaskActionJson) bool {
    if (!common.isSafeIdentifier(a.name)) return false;
    const img = if (a.image.len > 0)
        a.image
    else
        sysconfig.DEFAULT_GUEST_IMAGE_PATH;
    if (img[0] == '-' or std.mem.indexOf(u8, img, "..") != null) return false;
    for (img) |c| {
        if (c <= 0x20 or c >= 0x7f) return false;
    }
    const ram = if (a.ram.len > 0 and common.isSafeIdentifier(a.ram))
        a.ram
    else
        "192M";

    const dsx_bin = resolveDsxBin();
    const img_z = allocator.printSentinel("{s}", .{img}, 0) catch return false;
    defer allocator.free(img_z);
    const name_z = allocator.printSentinel("{s}", .{a.name}, 0) catch
        return false;
    defer allocator.free(name_z);
    const ram_z = allocator.printSentinel("{s}", .{ram}, 0) catch return false;
    defer allocator.free(ram_z);
    const stake_flag: [*:0]const u8 = if (a.delegate_stake)
        "--delegate-stake"
    else
        "--no-stake";

    if (resolveDoasPrefix()) |dp| {
        const argv: [*:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{
            dp,         dsx_bin.ptr, "run",     img_z.ptr, "--name",
            name_z.ptr, "--ram",     ram_z.ptr, "--leaf",  stake_flag,
            null,
        };
        return vote.spawnLoggedSubprocess(argv) == 0;
    }
    const argv: [*:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{
        dsx_bin.ptr, "run",     img_z.ptr, "--name",   name_z.ptr,
        "--ram",     ram_z.ptr, "--leaf",  stake_flag, null,
    };
    return vote.spawnLoggedSubprocess(argv) == 0;
}

fn runStopVm(allocator: std.mem.Allocator, a: TaskActionJson) bool {
    const tgt = if (a.target.len > 0) a.target else a.name;
    if (!common.isSafeIdentifier(tgt)) return false;
    const dsx_bin = resolveDsxBin();
    const tgt_z = allocator.printSentinel("{s}", .{tgt}, 0) catch
        return false;
    defer allocator.free(tgt_z);
    if (resolveDoasPrefix()) |dp| {
        const argv: [*:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{
            dp, dsx_bin.ptr, "stop", tgt_z.ptr, null,
        };
        return vote.spawnLoggedSubprocess(argv) == 0;
    }
    const argv: [*:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{
        dsx_bin.ptr, "stop", tgt_z.ptr, null,
    };
    return vote.spawnLoggedSubprocess(argv) == 0;
}

fn runShellCmd(allocator: std.mem.Allocator, a: TaskActionJson) bool {
    if (a.cmd.len == 0 or a.cmd.len > 1024) return false;
    const cmd_z = allocator.printSentinel("{s}", .{a.cmd}, 0) catch
        return false;
    defer allocator.free(cmd_z);
    const argv: [*:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{
        "/bin/sh", "-c", cmd_z.ptr, null,
    };
    return vote.spawnLoggedSubprocess(argv) == 0;
}

fn executeAction(allocator: std.mem.Allocator, a: TaskActionJson) bool {
    const op_str = if (a.action.len > 0) a.action else a.op;
    const kind = std.meta.stringToEnum(ActionKind, op_str) orelse return false;
    return switch (kind) {
        .write_file => runWriteFile(a),
        .install_pkg => runInstallPkg(allocator, a),
        .spawn_vm => runSpawnVm(allocator, a),
        .stop_vm => runStopVm(allocator, a),
        .run_cmd => runShellCmd(allocator, a),
        .report_board => true,
    };
}

fn postTaskReceipt(
    allocator: std.mem.Allocator,
    board_ip: u32,
    task_seq: u64,
    ok_cnt: usize,
    fail_cnt: usize,
    summary: []const u8,
) void {
    const status_s: []const u8 = if (fail_cnt == 0) "completed" else "failed";
    const s_esc = common.escapeJsonAlloc(allocator, summary) catch return;
    defer allocator.free(s_esc);
    const body = allocator.print(
        "{{\"kind\":\"task_receipt\",\"task_seq\":{d},\"status\":\"{s}\"," ++
            "\"actions_ok\":{d},\"summary\":\"{s}\"}}",
        .{ task_seq, status_s, ok_cnt, s_esc },
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
    ) catch return;
    defer resp.deinit(allocator);
    if (resp.status >= 400) return;

    const msgs = std.json.parseFromSlice(
        []const BoardEntryJson,
        allocator,
        resp.body,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    ) catch return;
    defer msgs.deinit();

    for (msgs.value) |m| {
        if (!has_p and m.target_cid >= common.CID_FIRST_CHILD) continue;
        if (hasCompletedSeq(m.seq, null)) continue;

        const prompt = allocator.print("TASK_PLAN: {s}", .{m.body}) catch
            continue;
        defer allocator.free(prompt);
        const sys_p =
            "Return JSON: {\"summary\":\"...\"," ++
            "\"actions\":[{\"action\":\"write_file|install_pkg|" ++
            "spawn_vm|stop_vm|run_cmd\",...}]}";
        const gw_res = gateway.queryLocalGatewayOrDirect(
            allocator,
            client,
            sys_p,
            prompt,
            null,
            512,
            "json",
        ) catch continue;
        defer gw_res.deinit(allocator);

        const plan = std.json.parseFromSlice(
            TaskPlanJson,
            allocator,
            gw_res.answer,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        ) catch continue;
        defer plan.deinit();

        var ok_cnt: usize = 0;
        var fail_cnt: usize = 0;
        const limit = @min(plan.value.actions.len, MAX_ACTIONS_PER_TASK);
        for (plan.value.actions[0..limit]) |act| {
            if (executeAction(allocator, act)) {
                ok_cnt += 1;
            } else {
                fail_cnt += 1;
            }
        }
        postTaskReceipt(
            allocator,
            board_ip,
            m.seq,
            ok_cnt,
            fail_cnt,
            plan.value.summary,
        );
        recordCompletedSeq(allocator, m.seq, null);
        report.tasks_completed += 1;
    }
}

test "agent/autonomy: validates safe write paths and completed seqs" {
    std.testing.refAllDecls(@This());
    const t = std.testing;
    try t.expect(isSafeAgentWritePath("/var/lib/diosix/agent/out.txt"));
    try t.expect(isSafeAgentWritePath("/tmp/health.ok"));
    try t.expect(!isSafeAgentWritePath("/etc/passwd"));
    try t.expect(!isSafeAgentWritePath("/tmp/../etc/shadow"));
    try t.expect(!isSafeAgentWritePath("/var/lib/diosix/agent-evil/x"));

    const seq_p = ".zig-cache/test-done-seqs.txt";
    var pz: [common.MAX_PATH_LEN]u8 = undefined;
    const pzs = common.toPathZ(seq_p, &pz).?;
    _ = linux.unlink(pzs.ptr);
    defer _ = linux.unlink(pzs.ptr);
    recordCompletedSeq(t.allocator, 12, seq_p);
    try t.expect(hasCompletedSeq(12, seq_p));
    try t.expect(!hasCompletedSeq(1, seq_p));
}
