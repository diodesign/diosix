// Child & Steward Charter Proposal Board Polling and Voting Logic.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const api = @import("../../api.zig");
const cfg_mod = @import("../config.zig");
const charter = @import("../../charter.zig");
const charter_crypto = @import("../../charter/crypto.zig");
const charter_ops = @import("../../charter/ops.zig");
const common = @import("../../common.zig");
const gateway = @import("../gateway.zig");
const net_http = @import("../../net/http.zig");
const ssh = @import("../../ssh.zig");
const sysconfig = @import("../../sysconfig.zig");

const AGENT_VOTED_PATH = sysconfig.AGENT_VOTED_PATH;
const MAX_VOTED_FILE_BYTES: usize = 64 * 1024;
const MAX_BOARD_LIST_BYTES: usize = 512 * 1024;

pub const StepReport = struct {
    proposals_seen: usize = 0,
    votes_cast: usize = 0,
    votes_approved: usize = 0,
    votes_rejected: usize = 0,
    sealed_version: u32 = 0,
    replicas_spawned: usize = 0,
    tasks_completed: usize = 0,
};

const BoardEntryJson = struct {
    seq: u64 = 0,
    author_cid: usize = 0,
    target_cid: usize = 0,
    topic: []const u8 = "",
    body: []const u8 = "",
};

const CharterProposalMsg = struct {
    kind: []const u8 = "",
    version: u32 = 0,
    sha256: []const u8 = "",
    toml: []const u8 = "",
};

fn hasVotedSha256(sha_hex: []const u8) bool {
    const raw = common.readBinaryFile(
        AGENT_VOTED_PATH,
        MAX_VOTED_FILE_BYTES,
    ) catch return false;
    defer common.unmapBinaryFile(raw);
    return std.mem.indexOf(u8, raw, sha_hex) != null;
}

fn recordVotedSha256(allocator: std.mem.Allocator, sha_hex: []const u8) void {
    net_http.ensureParentDir(AGENT_VOTED_PATH);
    const old = common.readBinaryFile(
        AGENT_VOTED_PATH,
        MAX_VOTED_FILE_BYTES,
    ) catch null;
    defer if (old) |o| common.unmapBinaryFile(o);
    const prev = if (old) |o| o else "";
    if (std.mem.indexOf(u8, prev, sha_hex) != null) return;
    const next = allocator.print("{s}{s}\n", .{ prev, sha_hex }) catch return;
    defer allocator.free(next);
    common.writeFile(AGENT_VOTED_PATH, next) catch {};
}

fn consultAgentBrain(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    parsed: *const charter.ParsedCharter,
) api.MissionVoteDecision {
    const has_p = net_http.isHasParent(client);
    var cfg = cfg_mod.loadAgentConfig(allocator, has_p);
    defer cfg.deinit();

    const prompt = allocator.print(
        "Review signed Mission v{d} (sha256={s}, goal={s}, " ++
            "min={d}, encrypt_volumes={}, wipe_volumes={}). " ++
            "Respond JSON with decision approve or reject.",
        .{
            parsed.version,
            &parsed.sha256_hex,
            parsed.goal(),
            parsed.totalMinReplicas(),
            parsed.encrypt_volumes,
            parsed.wipe_volumes,
        },
    ) catch return .approve;
    defer allocator.free(prompt);

    const res = gateway.queryLocalGatewayOrDirect(
        allocator,
        client,
        "",
        prompt,
        null,
        cfg.max_tokens,
        "json",
    ) catch return .approve;
    defer res.deinit(allocator);

    if (std.mem.indexOf(u8, res.answer, "\"reject\"") != null or
        std.mem.indexOf(u8, res.answer, "REJECT") != null)
    {
        return .reject;
    }
    return .approve;
}

pub fn processParentBoardProposals(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    report: *StepReport,
) void {
    const p_ip = net_http.resolveParentIpv4(client);
    const resp = net_http.httpClientRequest(
        allocator,
        p_ip,
        sysconfig.DEFAULT_BOARD_PORT,
        "GET",
        "/v1/messages?topic=charter",
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
        .{ .ignore_unknown_fields = true },
    ) catch return;
    defer msgs.deinit();

    const self_info = client.getInfo(common.CID_SELF) catch
        std.mem.zeroes(api.GuestInfo);
    const mmode = client.getMission(null) catch
        std.mem.zeroes(api.MissionArgs);
    const lo = ssh.parseIpv4("127.0.0.1") orelse 0;

    for (msgs.value) |m| {
        const prop = std.json.parseFromSlice(
            CharterProposalMsg,
            allocator,
            m.body,
            .{ .ignore_unknown_fields = true },
        ) catch continue;
        defer prop.deinit();
        if (!std.mem.eql(u8, prop.value.kind, "charter_proposal")) continue;

        const parsed = charter.parseCharterToml(prop.value.toml) catch
            continue;
        report.proposals_seen += 1;

        if (mmode.is_sealed != 0 and std.mem.eql(
            u8,
            &parsed.sha256_bytes,
            &mmode.charter_hash,
        )) {
            const pk_ok = mmode.has_pubkey == 0 or
                charter_crypto.verifyCharterSignature(
                    &parsed,
                    mmode.principal_pubkey,
                );
            if (pk_ok) {
                charter_ops.saveActiveCharterFile(prop.value.toml);
                if (self_info.child_count > 0) {
                    charter_ops.postProposalToBoard(
                        allocator,
                        lo,
                        sysconfig.DEFAULT_BOARD_PORT,
                        prop.value.toml,
                        &parsed,
                    ) catch {};
                }
            }
            continue;
        }

        if (hasVotedSha256(&parsed.sha256_hex)) continue;
        if (mmode.is_sealed != 0 and parsed.version <= mmode.version) {
            recordVotedSha256(allocator, &parsed.sha256_hex);
            continue;
        }

        charter_ops.savePendingCharterFile(prop.value.toml);
        if (self_info.child_count > 0) {
            charter_ops.postProposalToBoard(
                allocator,
                lo,
                sysconfig.DEFAULT_BOARD_PORT,
                prop.value.toml,
                &parsed,
            ) catch {};
        }

        // Deterministic constitutional guardrail vetoes before LLM brain runs.
        const chk = charter_ops.evaluateProposalAgainstState(client, &parsed);
        const mode: charter_ops.VoteMode = if (!chk.allowed)
            .reject
        else switch (consultAgentBrain(allocator, client, &parsed)) {
            .reject => .reject,
            else => .approve,
        };
        const out = charter_ops.castMissionVote(
            allocator,
            client,
            prop.value.toml,
            mode,
            sysconfig.DEFAULT_BOARD_PORT,
        ) catch continue;
        recordVotedSha256(allocator, &parsed.sha256_hex);
        report.votes_cast += 1;
        if (out.decision == .approve) {
            report.votes_approved += 1;
        } else {
            report.votes_rejected += 1;
        }
    }
}

pub fn spawnLoggedSubprocess(argv: [*:null]const ?[*:0]const u8) usize {
    net_http.ensureParentDir(sysconfig.AGENT_LOG_PATH);
    const pid_s: isize = @bitCast(linux.fork());
    if (pid_s < 0) return 1;
    if (pid_s == 0) {
        var lz_buf: [common.MAX_PATH_LEN]u8 = undefined;
        if (common.toPathZ(sysconfig.AGENT_LOG_PATH, &lz_buf)) |lz| {
            const wf: linux.O = .{
                .ACCMODE = .WRONLY,
                .CREAT = true,
                .APPEND = true,
            };
            const fd_s: isize = @bitCast(linux.open(lz.ptr, wf, 0o600));
            if (fd_s >= 0) {
                const fd: i32 = @intCast(fd_s);
                _ = linux.dup2(fd, 1);
                _ = linux.dup2(fd, 2);
                if (fd > 2) _ = linux.close(fd);
            }
        }
        const envp = [_:null]?[*:0]const u8{
            "PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin",
            null,
        };
        const prog = argv[0] orelse "/usr/sbin/dsx";
        _ = linux.execve(prog, argv, &envp);
        linux.exit_group(127);
    }
    const child_pid: i32 = @intCast(pid_s);
    var status: i32 = 0;
    while (true) {
        const w_s: isize = @bitCast(linux.waitpid(child_pid, &status, 0));
        if (w_s >= 0) break;
        if (w_s == -@as(isize, @backingInt(linux.E.INTR))) continue;
        return 1;
    }
    const st_u: u32 = @bitCast(status);
    if (linux.W.IFEXITED(st_u)) return linux.W.EXITSTATUS(st_u);
    return 1;
}

pub fn redirectDaemonStdio() void {
    net_http.ensureParentDir(sysconfig.AGENT_LOG_PATH);
    const dn: isize = @bitCast(
        linux.open(sysconfig.DEV_NULL_PATH, .{ .ACCMODE = .RDONLY }, 0),
    );
    if (dn >= 0) {
        const dfd: i32 = @intCast(dn);
        _ = linux.dup2(dfd, 0);
        if (dfd > 2) _ = linux.close(dfd);
    }
    var lz_buf: [common.MAX_PATH_LEN]u8 = undefined;
    if (common.toPathZ(sysconfig.AGENT_LOG_PATH, &lz_buf)) |lz| {
        const wf: linux.O = .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .APPEND = true,
        };
        const lfd_s: isize = @bitCast(linux.open(lz.ptr, wf, 0o600));
        if (lfd_s >= 0) {
            const lfd: i32 = @intCast(lfd_s);
            _ = linux.dup2(lfd, 1);
            _ = linux.dup2(lfd, 2);
            if (lfd > 2) _ = linux.close(lfd);
        }
    }
}

test "agent/loop/vote: StepReport defaults and proposal JSON decoding" {
    std.testing.refAllDecls(@This());
    const t = std.testing;
    const sample =
        "{\"kind\":\"charter_proposal\",\"version\":2," ++
        "\"sha256\":\"aa\",\"toml\":\"x\"}";
    const p = try std.json.parseFromSlice(
        CharterProposalMsg,
        t.allocator,
        sample,
        .{},
    );
    defer p.deinit();
    try t.expectEqual(@as(u32, 2), p.value.version);
    const r = StepReport{};
    try t.expectEqual(@as(usize, 0), r.votes_cast);
}
