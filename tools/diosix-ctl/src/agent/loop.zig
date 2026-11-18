// Autonomous Node Agent Reconciliation Loop & Board Consensus Handler.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const api = @import("../api.zig");
const autonomy = @import("autonomy.zig");
const charter = @import("../charter.zig");
const charter_ops = @import("../charter/ops.zig");
const common = @import("../common.zig");
const net_http = @import("../net/http.zig");
const registry = @import("../registry.zig");
const ssh = @import("../ssh.zig");
const swarm_proto = @import("../swarm/protocol.zig");
const swarm_srv = @import("../swarm/server.zig");
const sysconfig = @import("../sysconfig.zig");
const vote = @import("loop/vote.zig");

const PAGE_BYTES: u64 = 4096;

pub const StepReport = vote.StepReport;
pub const spawnLoggedSubprocess = vote.spawnLoggedSubprocess;

fn resolveDsxBin() [:0]const u8 {
    const cands = [_][:0]const u8{
        "/usr/sbin/dsx",
        "/usr/bin/dsx",
        "/usr/sbin/diosix-ctl",
    };
    return sysconfig.resolveFirstBin(&cands);
}

fn trySealPendingAmendmentOnRoot(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    report: *StepReport,
) void {
    const raw = common.readBinaryFile(
        sysconfig.CHARTER_PENDING_PATH,
        common.MAX_MANIFEST_SIZE,
    ) catch return;
    defer common.unmapBinaryFile(raw);

    const parsed = charter.parseCharterToml(raw) catch return;
    const mmode = client.getMission(parsed.sha256_bytes) catch
        std.mem.zeroes(api.MissionArgs);
    if (mmode.is_sealed != 0 and mmode.version >= parsed.version) return;

    const chk = charter_ops.evaluateProposalAgainstState(client, &parsed);
    if (!chk.allowed) return;

    if (mmode.is_sealed != 0) {
        if (mmode.eligible_stake_pages == 0) return;
        const lhs = mmode.approved_stake_pages *| 100;
        const rhs = mmode.eligible_stake_pages *|
            @as(u64, mmode.stake_quorum_pct);
        if (lhs < rhs) return;
    }

    const m_args = parsed.toMissionArgs(true) catch return;
    const sealed = client.sealMission(&m_args) catch return;
    charter_ops.saveActiveCharterFile(raw);

    var pend_z: [common.MAX_PATH_LEN]u8 = undefined;
    if (common.toPathZ(sysconfig.CHARTER_PENDING_PATH, &pend_z)) |pz| {
        _ = linux.unlink(pz.ptr);
    }
    const lo = ssh.parseIpv4("127.0.0.1") orelse 0;
    charter_ops.postProposalToBoard(
        allocator,
        lo,
        sysconfig.DEFAULT_BOARD_PORT,
        raw,
        &parsed,
    ) catch {};
    report.sealed_version = sealed.version;
}

fn countRunningUnitInstances(
    client: *api.DiosixClient,
    unit_id: []const u8,
) usize {
    const content = common.readBinaryFile(
        sysconfig.GUEST_REGISTRY_PATH,
        common.MAX_MANIFEST_SIZE,
    ) catch return 0;
    defer common.unmapBinaryFile(content);

    var count: usize = 0;
    var iter = registry.GuestRegistryIter.init(content);
    while (iter.next()) |entry| {
        if (!std.mem.eql(u8, entry.status, "running")) continue;
        if (!std.mem.startsWith(u8, entry.name, unit_id)) continue;
        if (entry.name.len <= unit_id.len or
            entry.name[unit_id.len] != '-') continue;
        if (client.getInfo(entry.cid)) |_| {
            count += 1;
        } else |_| {}
    }
    return count;
}

fn nameExistsInRegistry(vm_name: []const u8) bool {
    const content = common.readBinaryFile(
        sysconfig.GUEST_REGISTRY_PATH,
        common.MAX_MANIFEST_SIZE,
    ) catch return false;
    defer common.unmapBinaryFile(content);
    var iter = registry.GuestRegistryIter.init(content);
    while (iter.next()) |entry| {
        if (std.mem.eql(u8, entry.name, vm_name)) return true;
    }
    return false;
}

fn reconcileCharterUnitsOnRoot(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    report: *StepReport,
) void {
    const active = charter_ops.loadActiveCharterFile() orelse return;
    const m_info = client.getMission(null) catch
        std.mem.zeroes(api.MissionArgs);
    const c_info = client.getCharter() catch std.mem.zeroes(api.CharterArgs);
    if (m_info.is_sealed == 0 and c_info.is_sealed == 0) return;

    const id = swarm_proto.ensureNodeIdentity() catch return;
    const now = swarm_proto.nowUnixSec();
    const self_info = client.getInfo(common.CID_SELF) catch return;
    const avail_pages = self_info.max_ram_pages -| self_info.used_ram_pages;
    var avail_mb = (avail_pages * PAGE_BYTES) / (1024 * 1024);

    const dsx_bin = resolveDsxBin();

    for (active.units[0..active.unit_count]) |*u| {
        const want_host = swarm_proto.computeLocalUnitTarget(
            allocator,
            &id.pubkey_hex,
            u.target_instances,
            now,
        );
        const live = countRunningUnitInstances(client, u.id());
        if (live >= want_host) continue;

        var needed = want_host - live;
        var slot: usize = 1;
        while (needed > 0 and slot <= 32) : (slot += 1) {
            if (avail_mb < u.ram_mb + 64) break;
            const vm_name = allocator.print("{s}-{d}", .{
                u.id(),
                slot,
            }) catch break;
            defer allocator.free(vm_name);
            if (nameExistsInRegistry(vm_name)) continue;

            const art = if (u.artifact().len > 0)
                u.artifact()
            else
                sysconfig.DEFAULT_GUEST_IMAGE_PATH;
            const art_z = allocator.printSentinel("{s}", .{art}, 0) catch break;
            defer allocator.free(art_z);
            const name_z = allocator.printSentinel("{s}", .{vm_name}, 0) catch
                break;
            defer allocator.free(name_z);
            const vc_z = allocator.printSentinel("{d}", .{u.vcpus}, 0) catch
                break;
            defer allocator.free(vc_z);
            const ram_z = allocator.printSentinel("{d}M", .{u.ram_mb}, 0) catch
                break;
            defer allocator.free(ram_z);
            const pkg_z = allocator.printSentinel(
                "{s}",
                .{u.packages()},
                0,
            ) catch break;
            defer allocator.free(pkg_z);
            const net_z: [:0]const u8 = if (u.allow_wan_egress)
                "wan"
            else
                "local";

            const argv: [*:null]const ?[*:0]const u8 =
                &[_:null]?[*:0]const u8{
                    dsx_bin.ptr,      "run",              art_z.ptr,
                    "--name",         name_z.ptr,         "--vcpus",
                    vc_z.ptr,         "--ram",            ram_z.ptr,
                    "--packages",     pkg_z.ptr,          "--net",
                    net_z.ptr,        "--delegate-stake", "--tokens",
                    "100000",         "--budget-usd",     "1.00",
                    "--max-thinking", "low",              null,
                };
            if (spawnLoggedSubprocess(argv) == 0) {
                report.replicas_spawned += 1;
                avail_mb -|= u.ram_mb;
                needed -= 1;
            }
        }
    }
}

pub fn runAgentStep(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
) StepReport {
    var report = StepReport{};
    if (net_http.isHasParent(client)) {
        vote.processParentBoardProposals(allocator, client, &report);
        autonomy.processBoardTasks(allocator, client, &report);
        return report;
    }

    // Refresh swarm peers silently if a pending Charter awaits ratification.
    if (common.readBinaryFile(sysconfig.CHARTER_PENDING_PATH, 64)) |p| {
        common.unmapBinaryFile(p);
        const peers = swarm_proto.loadPeersAlloc(allocator) catch null;
        if (peers) |pl| {
            defer pl.deinit();
            for (pl.value) |peer| {
                const ep = peer.endpoint;
                if (swarm_srv.joinPeerEndpoint(allocator, client, ep)) |r| {
                    allocator.free(r.peer.node_pubkey);
                    allocator.free(r.peer.endpoint);
                    allocator.free(r.peer.principal_pubkey);
                    allocator.free(r.peer.charter_sha256);
                    allocator.free(r.peer.signature);
                    allocator.free(r.active_toml);
                } else |_| {}
            }
        }
    } else |_| {}

    trySealPendingAmendmentOnRoot(allocator, client, &report);
    reconcileCharterUnitsOnRoot(allocator, client, &report);
    autonomy.processBoardTasks(allocator, client, &report);
    return report;
}

pub fn runAgentDaemon(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    interval_sec: u32,
    daemon: bool,
) !void {
    if (daemon) {
        if (net_http.isPidFileRunning(sysconfig.AGENT_PID_PATH) != null) return;
        const pid_s: isize = @bitCast(linux.fork());
        if (pid_s < 0) return error.ForkFailed;
        if (pid_s > 0) {
            net_http.ensureParentDir(sysconfig.AGENT_PID_PATH);
            var pb: [32]u8 = undefined;
            const ps = std.fmt.bufPrint(&pb, "{d}\n", .{pid_s}) catch return;
            common.writePrivateFile(sysconfig.AGENT_PID_PATH, ps) catch {};
            return;
        }
        _ = linux.setsid();
        vote.redirectDaemonStdio();
    }

    const sec: isize = @intCast(@max(@as(u32, 1), interval_sec));
    while (true) {
        _ = runAgentStep(allocator, client);
        var ts = linux.timespec{ .sec = sec, .nsec = 0 };
        _ = linux.nanosleep(&ts, null);
    }
}

test "agent/loop: StepReport defaults and vote submodule wired" {
    std.testing.refAllDecls(@This());
    _ = vote;
    const r = StepReport{};
    try std.testing.expectEqual(@as(usize, 0), r.replicas_spawned);
}
