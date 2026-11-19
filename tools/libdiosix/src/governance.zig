// Diosix Governance, Charter, Mission, and Whisper IOCTL Helpers.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const api = @import("lib.zig");

pub fn sealCharter(
    client: *api.DiosixClient,
    args: *const api.CharterArgs,
) !void {
    const fd = try client.getFd();
    _ = try api.checkIoctlRc(
        linux.ioctl(fd, api.IOCTL_SEAL_CHARTER, @intFromPtr(args)),
    );
}

pub fn getCharter(client: *api.DiosixClient) !api.CharterArgs {
    const fd = try client.getFd();
    var args = std.mem.zeroes(api.CharterArgs);
    _ = try api.checkIoctlRc(
        linux.ioctl(fd, api.IOCTL_GET_CHARTER, @intFromPtr(&args)),
    );
    return args;
}

pub fn sealMission(
    client: *api.DiosixClient,
    args: *const api.MissionArgs,
) !api.MissionArgs {
    const fd = try client.getFd();
    var mutable = args.*;
    _ = try api.checkIoctlRc(
        linux.ioctl(fd, api.IOCTL_SEAL_MISSION, @intFromPtr(&mutable)),
    );
    return mutable;
}

pub fn getMission(
    client: *api.DiosixClient,
    proposal_hash_opt: ?[32]u8,
) !api.MissionArgs {
    const fd = try client.getFd();
    var args = std.mem.zeroes(api.MissionArgs);
    if (proposal_hash_opt) |h| args.charter_hash = h;
    _ = try api.checkIoctlRc(
        linux.ioctl(fd, api.IOCTL_GET_MISSION, @intFromPtr(&args)),
    );
    return args;
}

pub fn voteMission(
    client: *api.DiosixClient,
    proposal_hash: [32]u8,
    decision: api.MissionVoteDecision,
) !api.MissionVoteArgs {
    const fd = try client.getFd();
    var args = api.MissionVoteArgs{
        .proposal_hash = proposal_hash,
        .decision = @backingInt(decision),
    };
    _ = try api.checkIoctlRc(
        linux.ioctl(fd, api.IOCTL_VOTE_MISSION, @intFromPtr(&args)),
    );
    return args;
}

pub fn ratifyCharter(client: *api.DiosixClient, target_cid: usize) !usize {
    const fd = try client.getFd();
    const signed_rc = try api.checkIoctlRc(
        linux.ioctl(fd, api.IOCTL_RATIFY_CHARTER, target_cid),
    );
    return @intCast(signed_rc);
}

pub fn resetSteward(client: *api.DiosixClient, target_cid: usize) !usize {
    const fd = try client.getFd();
    const signed_rc = try api.checkIoctlRc(
        linux.ioctl(fd, api.IOCTL_RESET_STEWARD, target_cid),
    );
    return @intCast(signed_rc);
}

pub fn requestRootFailover(
    client: *api.DiosixClient,
    standby_cid: usize,
) !usize {
    const fd = try client.getFd();
    const signed_rc = try api.checkIoctlRc(
        linux.ioctl(fd, api.IOCTL_REQUEST_ROOT_FAILOVER, standby_cid),
    );
    return @intCast(signed_rc);
}

pub fn whisperSend(
    client: *api.DiosixClient,
    target_cid: usize,
    data: []const u8,
) !usize {
    if (data.len == 0) return 0;
    const fd = try client.getFd();
    var args = api.ConsoleArgs{
        .target_cid = target_cid,
        .data_ptr = @intFromPtr(data.ptr),
        .max_len = data.len,
        .actual_len = 0,
    };
    _ = try api.checkIoctlRc(
        linux.ioctl(fd, api.IOCTL_WHISPER_SEND, @intFromPtr(&args)),
    );
    return @intCast(args.actual_len);
}

pub fn whisperRecv(client: *api.DiosixClient, buffer: []u8) !usize {
    if (buffer.len == 0) return 0;
    const fd = try client.getFd();
    var args = api.ConsoleArgs{
        .target_cid = 0,
        .data_ptr = @intFromPtr(buffer.ptr),
        .max_len = buffer.len,
        .actual_len = 0,
    };
    _ = try api.checkIoctlRc(
        linux.ioctl(fd, api.IOCTL_WHISPER_RECV, @intFromPtr(&args)),
    );
    return @min(@as(usize, @intCast(args.actual_len)), buffer.len);
}

test "api/governance: mission ioctl constants match ABI offsets" {
    std.testing.refAllDecls(@This());
    try std.testing.expectEqual(@as(u32, 0x101e), api.IOCTL_SEAL_MISSION);
    try std.testing.expectEqual(@as(u32, 0x101f), api.IOCTL_GET_MISSION);
    try std.testing.expectEqual(@as(u32, 0x1020), api.IOCTL_VOTE_MISSION);
}
