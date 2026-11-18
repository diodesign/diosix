// Bounded Autonomous Steward Action Executors (Spawn, Stop, SSH, Grant, Write).
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const api = @import("../../api.zig");
const cfg_mod = @import("../config.zig");
const common = @import("../../common.zig");
const net_http = @import("../../net/http.zig");
const pkg_policy = @import("../../pkg/policy.zig");
const ssh = @import("../../ssh.zig");
const sysconfig = @import("../../sysconfig.zig");
const vote = @import("../loop/vote.zig");

pub const ActionKind = enum {
    write_file,
    install_pkg,
    spawn_vm,
    stop_vm,
    run_cmd,
    report_board,
    ssh_child,
    grant_quota,
};

pub const TaskActionJson = struct {
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
    tokens: []const u8 = "",
    budget_usd: []const u8 = "",
    max_thinking: []const u8 = "",
    leaf: bool = true,
    delegate_stake: bool = false,
};

pub const TaskPlanJson = struct {
    summary: []const u8 = "",
    actions: []const TaskActionJson = &.{},
};

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

pub fn isSafeChildName(name: []const u8) bool {
    return common.isSafeIdentifier(name) and name[0] != '-';
}

pub fn isSafeBudgetToken(s: []const u8) bool {
    if (s.len == 0 or s.len > 32) return false;
    var has_digit = false;
    for (s, 0..) |c, idx| {
        if (c == '+' and idx == 0) continue;
        if (c >= '0' and c <= '9') {
            has_digit = true;
            continue;
        }
        if (c == '.' and idx > 0) continue;
        return false;
    }
    return has_digit;
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

fn ensureLocalDefaultImage(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    req_img: []const u8,
) ?[]u8 {
    if (!std.mem.eql(u8, req_img, sysconfig.DEFAULT_GUEST_IMAGE_PATH)) {
        return null;
    }
    if (common.fileExistsPath(sysconfig.DEFAULT_GUEST_IMAGE_PATH)) return null;
    const dst: []const u8 = if (linux.geteuid() == 0)
        sysconfig.DEFAULT_GUEST_IMAGE_PATH
    else
        sysconfig.AGENT_WORK_DIR ++ "/diosix-node.elf";
    var dst_buf: [common.MAX_PATH_LEN]u8 = undefined;
    const dst_z = common.toPathZ(dst, &dst_buf) orelse return null;
    if (common.fileExistsPath(dst_z.ptr)) {
        return allocator.dupe(u8, dst) catch null;
    }
    if (!net_http.isHasParent(client)) return null;
    net_http.ensureParentDir(dst);

    const part_z = allocator.printSentinel("{s}.part", .{dst}, 0) catch
        return null;
    defer allocator.free(part_z);
    const parent_ip = net_http.resolveParentIpv4(client);
    var ip_buf: [16]u8 = undefined;
    const ip_str = net_http.formatIpv4(parent_ip, &ip_buf);
    const url_z = allocator.printSentinel(
        "http://{s}:{d}/v1/images/diosix-node.elf",
        .{ ip_str, sysconfig.DEFAULT_PKG_PORT },
        0,
    ) catch return null;
    defer allocator.free(url_z);
    const wget_bin = sysconfig.resolveBin(
        sysconfig.WGET_LOCAL_BIN,
        sysconfig.WGET_BIN,
    );
    const wget_argv: [*:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{
        wget_bin.ptr, "-q", "-T", "15", "-O", part_z.ptr, url_z.ptr, null,
    };
    if (vote.spawnLoggedSubprocess(wget_argv) != 0) {
        _ = linux.unlink(part_z.ptr);
        return null;
    }
    const rn: isize = @bitCast(linux.rename(part_z.ptr, dst_z.ptr));
    if (rn < 0) {
        _ = linux.unlink(part_z.ptr);
        return null;
    }
    return allocator.dupe(u8, dst) catch null;
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

fn runSpawnVm(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    a: TaskActionJson,
) bool {
    if (!isSafeChildName(a.name)) return false;
    const req_img = if (a.image.len > 0)
        a.image
    else
        sysconfig.DEFAULT_GUEST_IMAGE_PATH;
    if (req_img[0] == '-' or std.mem.indexOf(u8, req_img, "..") != null) {
        return false;
    }
    for (req_img) |c| {
        if (c <= 0x20 or c >= 0x7f) return false;
    }
    const cached_img = ensureLocalDefaultImage(allocator, client, req_img);
    defer if (cached_img) |ci| allocator.free(ci);
    const img = cached_img orelse req_img;
    const ram = if (a.ram.len > 0 and isSafeChildName(a.ram)) a.ram else "192M";

    const dsx_bin = resolveDsxBin();
    const img_z = allocator.printSentinel("{s}", .{img}, 0) catch return false;
    defer allocator.free(img_z);
    const name_z = allocator.printSentinel("{s}", .{a.name}, 0) catch
        return false;
    defer allocator.free(name_z);
    const ram_z = allocator.printSentinel("{s}", .{ram}, 0) catch return false;
    defer allocator.free(ram_z);
    const tok_z: ?[:0]u8 = if (isSafeBudgetToken(a.tokens))
        allocator.printSentinel("{s}", .{a.tokens}, 0) catch null
    else
        null;
    defer if (tok_z) |v| allocator.free(v);
    const usd_z: ?[:0]u8 = if (isSafeBudgetToken(a.budget_usd))
        allocator.printSentinel("{s}", .{a.budget_usd}, 0) catch null
    else
        null;
    defer if (usd_z) |v| allocator.free(v);
    const tier_z: ?[:0]u8 = if (cfg_mod.parseThinkingLevel(a.max_thinking)) |l|
        allocator.printSentinel("{s}", .{@tagName(l)}, 0) catch null
    else
        null;
    defer if (tier_z) |v| allocator.free(v);

    var argv: [24:null]?[*:0]const u8 = @splat(null);
    var argc: usize = 0;
    if (resolveDoasPrefix()) |dp| {
        argv[argc] = dp;
        argc += 1;
    }
    argv[argc] = dsx_bin.ptr;
    argv[argc + 1] = "run";
    argv[argc + 2] = img_z.ptr;
    argv[argc + 3] = "--name";
    argv[argc + 4] = name_z.ptr;
    argv[argc + 5] = "--ram";
    argv[argc + 6] = ram_z.ptr;
    argc += 7;
    if (a.leaf) {
        argv[argc] = "--leaf";
        argv[argc + 1] = "--pcpu";
        argv[argc + 2] = "10";
        argc += 3;
    }
    argv[argc] = if (a.delegate_stake) "--delegate-stake" else "--no-stake";
    argc += 1;
    if (tok_z) |v| {
        argv[argc] = "--tokens";
        argv[argc + 1] = v.ptr;
        argc += 2;
    }
    if (usd_z) |v| {
        argv[argc] = "--budget-usd";
        argv[argc + 1] = v.ptr;
        argc += 2;
    }
    if (tier_z) |v| {
        argv[argc] = "--max-thinking";
        argv[argc + 1] = v.ptr;
        argc += 2;
    }
    return vote.spawnLoggedSubprocess(&argv) == 0;
}

fn isGuestInRegistry(tgt: []const u8) bool {
    const content = common.readBinaryFile(
        sysconfig.GUEST_REGISTRY_PATH,
        common.MAX_MANIFEST_SIZE,
    ) catch return false;
    defer common.unmapBinaryFile(content);
    var iter = common.GuestRegistryIter.init(content);
    while (iter.next()) |e| {
        if (std.mem.eql(u8, e.name, tgt)) return true;
    }
    return false;
}

fn runStopVm(allocator: std.mem.Allocator, a: TaskActionJson) bool {
    const tgt = if (a.target.len > 0) a.target else a.name;
    if (!isSafeChildName(tgt)) return false;
    if (!isGuestInRegistry(tgt)) return true;
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

fn runSshChild(allocator: std.mem.Allocator, a: TaskActionJson) bool {
    const tgt = if (a.target.len > 0) a.target else a.name;
    if (!isSafeChildName(tgt)) return false;
    if (a.cmd.len == 0 or a.cmd.len > 1536) return false;
    const dsx_bin = resolveDsxBin();
    const tgt_z = allocator.printSentinel("{s}", .{tgt}, 0) catch
        return false;
    defer allocator.free(tgt_z);
    const cmd_z = allocator.printSentinel("{s}", .{a.cmd}, 0) catch
        return false;
    defer allocator.free(cmd_z);
    var argv: [8:null]?[*:0]const u8 = @splat(null);
    var argc: usize = 0;
    if (resolveDoasPrefix()) |dp| {
        argv[argc] = dp;
        argc += 1;
    }
    argv[argc] = dsx_bin.ptr;
    argv[argc + 1] = "ssh";
    argv[argc + 2] = tgt_z.ptr;
    argv[argc + 3] = "--";
    argv[argc + 4] = cmd_z.ptr;
    return vote.spawnLoggedSubprocess(&argv) == 0;
}

fn runGrantQuota(allocator: std.mem.Allocator, a: TaskActionJson) bool {
    const tgt = if (a.target.len > 0) a.target else a.name;
    if (!isSafeChildName(tgt)) return false;
    const dsx_bin = resolveDsxBin();
    const tgt_z = allocator.printSentinel("{s}", .{tgt}, 0) catch
        return false;
    defer allocator.free(tgt_z);
    const tok_z: ?[:0]u8 = if (isSafeBudgetToken(a.tokens))
        allocator.printSentinel("{s}", .{a.tokens}, 0) catch null
    else
        null;
    defer if (tok_z) |v| allocator.free(v);
    const usd_z: ?[:0]u8 = if (isSafeBudgetToken(a.budget_usd))
        allocator.printSentinel("{s}", .{a.budget_usd}, 0) catch null
    else
        null;
    defer if (usd_z) |v| allocator.free(v);
    const tier_z: ?[:0]u8 = if (cfg_mod.parseThinkingLevel(a.max_thinking)) |l|
        allocator.printSentinel("{s}", .{@tagName(l)}, 0) catch null
    else
        null;
    defer if (tier_z) |v| allocator.free(v);
    if (tok_z == null and usd_z == null and tier_z == null) return false;

    var argv: [12:null]?[*:0]const u8 = @splat(null);
    var argc: usize = 0;
    if (resolveDoasPrefix()) |dp| {
        argv[argc] = dp;
        argc += 1;
    }
    argv[argc] = dsx_bin.ptr;
    argv[argc + 1] = "agent";
    argv[argc + 2] = "grant";
    argv[argc + 3] = tgt_z.ptr;
    argc += 4;
    if (tok_z) |v| {
        argv[argc] = "--tokens";
        argv[argc + 1] = v.ptr;
        argc += 2;
    }
    if (usd_z) |v| {
        argv[argc] = "--budget-usd";
        argv[argc + 1] = v.ptr;
        argc += 2;
    }
    if (tier_z) |v| {
        argv[argc] = "--max-thinking";
        argv[argc + 1] = v.ptr;
        argc += 2;
    }
    return vote.spawnLoggedSubprocess(&argv) == 0;
}

fn runShellCmd(allocator: std.mem.Allocator, a: TaskActionJson) bool {
    if (a.cmd.len == 0 or a.cmd.len > 1536) return false;
    const cmd_z = allocator.printSentinel("{s}", .{a.cmd}, 0) catch
        return false;
    defer allocator.free(cmd_z);
    const argv: [*:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{
        "/bin/sh", "-c", cmd_z.ptr, null,
    };
    return vote.spawnLoggedSubprocess(argv) == 0;
}

pub fn executeAction(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    a: TaskActionJson,
) bool {
    const op_str = if (a.action.len > 0) a.action else a.op;
    const kind = std.meta.stringToEnum(ActionKind, op_str) orelse return false;
    return switch (kind) {
        .write_file => runWriteFile(a),
        .install_pkg => runInstallPkg(allocator, a),
        .spawn_vm => runSpawnVm(allocator, client, a),
        .stop_vm => runStopVm(allocator, a),
        .run_cmd => runShellCmd(allocator, a),
        .report_board => true,
        .ssh_child => runSshChild(allocator, a),
        .grant_quota => runGrantQuota(allocator, a),
    };
}

test "agent/autonomy/actions: validates paths, child names, and budgets" {
    std.testing.refAllDecls(@This());
    const t = std.testing;
    try t.expect(isSafeAgentWritePath("/var/lib/diosix/agent/out.txt"));
    try t.expect(isSafeAgentWritePath("/tmp/health.ok"));
    try t.expect(!isSafeAgentWritePath("/etc/passwd"));
    try t.expect(!isSafeAgentWritePath("/tmp/../etc/shadow"));
    try t.expect(!isSafeAgentWritePath("/var/lib/diosix/agent-evil/x"));
    try t.expect(isSafeChildName("kv-1"));
    try t.expect(!isSafeChildName("-evil"));
    try t.expect(isSafeBudgetToken("+0.10"));
    try t.expect(isSafeBudgetToken("50000"));
    try t.expect(!isSafeBudgetToken("-1"));
}
