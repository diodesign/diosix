// C ABI bindings for libdiosix over /dev/diosix ioctls.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const lib = @import("lib.zig");

pub const OK: c_int = 0;
pub const ERR_NO_DEVICE: c_int = -1;
pub const ERR_DENIED: c_int = -2;
pub const ERR_NOT_SUPPORTED: c_int = -3;
pub const ERR_WOULD_BLOCK: c_int = -4;
pub const ERR_INVALID_ARG: c_int = -5;
pub const ERR_NO_MEMORY: c_int = -6;
pub const ERR_HYPERCALL: c_int = -7;

const MAX_CONTEXTS: usize = 64;

const CtxSlot = struct {
    in_use: std.atomic.Value(bool) = .init(false),
    client: lib.DiosixClient = undefined,
};

var ctx_pool: [MAX_CONTEXTS]CtxSlot = @splat(.{});

fn allocSlot() ?*CtxSlot {
    for (&ctx_pool) |*slot| {
        if (slot.in_use.cmpxchgStrong(
            false,
            true,
            .acq_rel,
            .acquire,
        ) == null) return slot;
    }
    return null;
}

fn freeSlot(slot: *CtxSlot) void {
    slot.client.deinit();
    slot.in_use.store(false, .release);
}

fn getClient(ctx_raw: ?*anyopaque) ?*lib.DiosixClient {
    const raw = ctx_raw orelse return null;
    const addr = @intFromPtr(raw);
    const base = @intFromPtr(&ctx_pool[0]);
    const end = base + @sizeOf(@TypeOf(ctx_pool));
    if (addr < base or addr >= end) return null;
    if ((addr - base) % @sizeOf(CtxSlot) != 0) return null;
    const slot: *CtxSlot = @ptrCast(@alignCast(raw));
    if (!slot.in_use.load(.acquire)) return null;
    return &slot.client;
}

fn sliceMut(raw: ?*anyopaque, len: usize) ?[]u8 {
    if (len == 0) return &.{};
    const p: [*]u8 = @ptrCast(raw orelse return null);
    return p[0..len];
}

fn sliceConst(raw: ?*const anyopaque, len: usize) ?[]const u8 {
    if (len == 0) return &.{};
    const p: [*]const u8 = @ptrCast(raw orelse return null);
    return p[0..len];
}

fn mapErr(err: anyerror) c_int {
    return switch (err) {
        error.DeviceNotFound => ERR_NO_DEVICE,
        error.PermissionDenied => ERR_DENIED,
        error.NotSupported => ERR_NOT_SUPPORTED,
        error.WouldBlock => ERR_WOULD_BLOCK,
        error.OutOfMemory => ERR_NO_MEMORY,
        else => ERR_HYPERCALL,
    };
}

pub export fn diosix_strerror(err: c_int) callconv(.c) [*:0]const u8 {
    return switch (err) {
        OK => "ok",
        ERR_NO_DEVICE => "diosix device not found",
        ERR_DENIED => "permission denied",
        ERR_NOT_SUPPORTED => "operation not supported",
        ERR_WOULD_BLOCK => "would block",
        ERR_INVALID_ARG => "invalid argument",
        ERR_NO_MEMORY => "out of memory",
        ERR_HYPERCALL => "hypercall failed",
        else => "unknown error",
    };
}

pub export fn diosix_open_status(
    path: ?[*:0]const u8,
    out_ctx: ?*?*anyopaque,
) callconv(.c) c_int {
    const p = path orelse return ERR_INVALID_ARG;
    const out = out_ctx orelse return ERR_INVALID_ARG;
    out.* = null;
    var client = lib.DiosixClient.initWithPath(p);
    _ = client.getFd() catch |err| {
        client.deinit();
        return mapErr(err);
    };
    const slot = allocSlot() orelse {
        client.deinit();
        return ERR_NO_MEMORY;
    };
    slot.client = client;
    out.* = @ptrCast(slot);
    return OK;
}

pub export fn diosix_open_path(path: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    var ctx: ?*anyopaque = null;
    if (diosix_open_status(path, &ctx) == OK) return ctx;
    return null;
}

pub export fn diosix_open() callconv(.c) ?*anyopaque {
    return diosix_open_path(lib.DEFAULT_DEVICE_PATH);
}

pub export fn diosix_close(ctx_raw: ?*anyopaque) callconv(.c) void {
    const raw = ctx_raw orelse return;
    _ = getClient(raw) orelse return;
    freeSlot(@ptrCast(@alignCast(raw)));
}

pub export fn diosix_fd(ctx_raw: ?*const anyopaque) callconv(.c) c_int {
    const c = getClient(@constCast(ctx_raw)) orelse return ERR_INVALID_ARG;
    const fd = c.getFd() catch |err| return mapErr(err);
    return @intCast(fd);
}

pub export fn diosix_get_hv_info(
    ctx_raw: ?*anyopaque,
    out_info: ?*lib.HypervisorInfo,
) callconv(.c) c_int {
    const c = getClient(ctx_raw) orelse return ERR_INVALID_ARG;
    const out = out_info orelse return ERR_INVALID_ARG;
    out.* = c.getHypervisorInfo() catch |err| return mapErr(err);
    return OK;
}

pub export fn diosix_get_guest_info(
    ctx_raw: ?*anyopaque,
    target_cid: u64,
    out_info: ?*lib.GuestInfo,
) callconv(.c) c_int {
    const c = getClient(ctx_raw) orelse return ERR_INVALID_ARG;
    const out = out_info orelse return ERR_INVALID_ARG;
    out.* = c.getInfo(@intCast(target_cid)) catch |err| return mapErr(err);
    return OK;
}

pub export fn diosix_drop_trust(ctx_raw: ?*anyopaque) callconv(.c) c_int {
    const c = getClient(ctx_raw) orelse return ERR_INVALID_ARG;
    c.dropTrust() catch |err| return mapErr(err);
    return OK;
}

pub export fn diosix_yield(ctx_raw: ?*anyopaque) callconv(.c) c_int {
    const c = getClient(ctx_raw) orelse return ERR_INVALID_ARG;
    c.yield() catch |err| return mapErr(err);
    return OK;
}

pub export fn diosix_wait_event(
    ctx_raw: ?*anyopaque,
    target_cid: u64,
    flags: u64,
    out_event: ?*lib.Event,
) callconv(.c) c_int {
    const c = getClient(ctx_raw) orelse return ERR_INVALID_ARG;
    const out = out_event orelse return ERR_INVALID_ARG;
    out.* = c.waitEvent(@intCast(target_cid), flags) catch |err|
        return mapErr(err);
    return OK;
}

pub export fn diosix_run_guest(
    ctx_raw: ?*anyopaque,
    args_opt: ?*const lib.RunArgs,
    out_cid: ?*u64,
) callconv(.c) c_int {
    const c = getClient(ctx_raw) orelse return ERR_INVALID_ARG;
    const a = args_opt orelse return ERR_INVALID_ARG;
    if (a.elf_ptr == 0 or a.elf_size == 0) return ERR_INVALID_ARG;
    const elf_ptr: [*]const u8 = @ptrFromInt(@as(usize, @intCast(a.elf_ptr)));
    const dtb_slice: []const u8 = if (a.dtb_ptr != 0 and a.dtb_size > 0)
        @as([*]const u8, @ptrFromInt(@as(usize, @intCast(a.dtb_ptr))))[0..@intCast(
            a.dtb_size,
        )]
    else
        &.{};
    const cid = c.run(
        @intCast(a.child_id),
        elf_ptr[0..@intCast(a.elf_size)],
        dtb_slice,
        @intCast(a.target_arch),
        @intCast(a.flags),
    ) catch |err| return mapErr(err);
    if (out_cid) |out| out.* = @intCast(cid);
    return OK;
}

pub export fn diosix_start_guest(
    ctx_raw: ?*anyopaque,
    target_cid: u64,
    entry_point: u64,
    dtb_ptr: u64,
    out_val: ?*u64,
) callconv(.c) c_int {
    const c = getClient(ctx_raw) orelse return ERR_INVALID_ARG;
    const v = c.startGuest(
        @intCast(target_cid),
        @intCast(entry_point),
        @intCast(dtb_ptr),
    ) catch |err| return mapErr(err);
    if (out_val) |out| out.* = @intCast(v);
    return OK;
}

pub export fn diosix_terminate(
    ctx_raw: ?*anyopaque,
    target_cid: u64,
    exit_code: u64,
) callconv(.c) c_int {
    const c = getClient(ctx_raw) orelse return ERR_INVALID_ARG;
    c.terminate(@intCast(target_cid), @intCast(exit_code)) catch |err|
        return mapErr(err);
    return OK;
}

pub export fn diosix_set_quota(
    ctx_raw: ?*anyopaque,
    args_opt: ?*const lib.QuotaArgs,
) callconv(.c) c_int {
    const c = getClient(ctx_raw) orelse return ERR_INVALID_ARG;
    const a = args_opt orelse return ERR_INVALID_ARG;
    c.setQuotaWithPcpu(
        @intCast(a.target_cid),
        @intCast(a.max_ram_pages),
        @intCast(a.max_vcpus),
        a.max_child_depth,
        a.max_descendants,
        @intCast(a.pcpu_quota_pct),
        @intCast(a.logical_ram_pages),
    ) catch |err| return mapErr(err);
    return OK;
}

pub export fn diosix_get_manifest(
    ctx_raw: ?*anyopaque,
    target_cid: u64,
    buf_raw: ?*anyopaque,
    max_len: usize,
    out_len: ?*usize,
) callconv(.c) c_int {
    const c = getClient(ctx_raw) orelse return ERR_INVALID_ARG;
    const buf = sliceMut(buf_raw, max_len) orelse return ERR_INVALID_ARG;
    const n = c.getManifest(@intCast(target_cid), buf) catch |err|
        return mapErr(err);
    if (out_len) |out| out.* = n;
    return OK;
}

pub export fn diosix_set_manifest(
    ctx_raw: ?*anyopaque,
    target_cid: u64,
    buf_raw: ?*const anyopaque,
    len: usize,
) callconv(.c) c_int {
    const c = getClient(ctx_raw) orelse return ERR_INVALID_ARG;
    const data = sliceConst(buf_raw, len) orelse return ERR_INVALID_ARG;
    c.setManifest(@intCast(target_cid), data) catch |err| return mapErr(err);
    return OK;
}

pub export fn diosix_console_read(
    ctx_raw: ?*anyopaque,
    target_cid: u64,
    buf_raw: ?*anyopaque,
    max_len: usize,
    out_len: ?*usize,
) callconv(.c) c_int {
    const c = getClient(ctx_raw) orelse return ERR_INVALID_ARG;
    const buf = sliceMut(buf_raw, max_len) orelse return ERR_INVALID_ARG;
    const n = c.consoleRead(@intCast(target_cid), buf) catch |err|
        return mapErr(err);
    if (out_len) |out| out.* = n;
    return OK;
}

pub export fn diosix_console_write(
    ctx_raw: ?*anyopaque,
    target_cid: u64,
    buf_raw: ?*const anyopaque,
    len: usize,
    out_len: ?*usize,
) callconv(.c) c_int {
    const c = getClient(ctx_raw) orelse return ERR_INVALID_ARG;
    const data = sliceConst(buf_raw, len) orelse return ERR_INVALID_ARG;
    const n = c.consoleWrite(@intCast(target_cid), data) catch |err|
        return mapErr(err);
    if (out_len) |out| out.* = n;
    return OK;
}

pub export fn diosix_set_net_policy(
    ctx_raw: ?*anyopaque,
    target_cid: u64,
    flags: u64,
    upstream_cid: u64,
) callconv(.c) c_int {
    const c = getClient(ctx_raw) orelse return ERR_INVALID_ARG;
    c.setNetPolicy(@intCast(target_cid), flags, @intCast(upstream_cid)) catch |err|
        return mapErr(err);
    return OK;
}

pub export fn diosix_map_child_mem(
    ctx_raw: ?*anyopaque,
    target_cid: u64,
    child_gpa: u64,
    parent_gpa: u64,
    size: usize,
    flags: u64,
    out_ptr: ?*?*anyopaque,
) callconv(.c) c_int {
    const c = getClient(ctx_raw) orelse return ERR_INVALID_ARG;
    const out = out_ptr orelse return ERR_INVALID_ARG;
    if (size == 0) return ERR_INVALID_ARG;
    const mapped = c.mapChildMemory(
        @intCast(target_cid),
        @intCast(child_gpa),
        @intCast(parent_gpa),
        size,
        @intCast(flags),
    ) catch |err| return mapErr(err);
    out.* = @ptrCast(mapped.ptr);
    return OK;
}

pub export fn diosix_unmap_child_mem(
    ctx_raw: ?*anyopaque,
    ptr_raw: ?*anyopaque,
    size: usize,
    parent_gpa: u64,
) callconv(.c) c_int {
    const c = getClient(ctx_raw) orelse return ERR_INVALID_ARG;
    const ptr = ptr_raw orelse return ERR_INVALID_ARG;
    if (size == 0) return ERR_INVALID_ARG;
    const u8_ptr: [*]u8 = @ptrCast(ptr);
    c.unmapChildMemory(u8_ptr[0..size], @intCast(parent_gpa)) catch |err|
        return mapErr(err);
    return OK;
}

pub export fn diosix_seal_charter(
    ctx_raw: ?*anyopaque,
    args_opt: ?*const lib.CharterArgs,
) callconv(.c) c_int {
    const c = getClient(ctx_raw) orelse return ERR_INVALID_ARG;
    const a = args_opt orelse return ERR_INVALID_ARG;
    c.sealCharter(a) catch |err| return mapErr(err);
    return OK;
}

pub export fn diosix_get_charter(
    ctx_raw: ?*anyopaque,
    out_args: ?*lib.CharterArgs,
) callconv(.c) c_int {
    const c = getClient(ctx_raw) orelse return ERR_INVALID_ARG;
    const out = out_args orelse return ERR_INVALID_ARG;
    out.* = c.getCharter() catch |err| return mapErr(err);
    return OK;
}

pub export fn diosix_ratify_charter(
    ctx_raw: ?*anyopaque,
    target_cid: u64,
    out_mask: ?*u64,
) callconv(.c) c_int {
    const c = getClient(ctx_raw) orelse return ERR_INVALID_ARG;
    const mask = c.ratifyCharter(@intCast(target_cid)) catch |err|
        return mapErr(err);
    if (out_mask) |out| out.* = @intCast(mask);
    return OK;
}

pub export fn diosix_reset_steward(
    ctx_raw: ?*anyopaque,
    target_cid: u64,
    out_val: ?*u64,
) callconv(.c) c_int {
    const c = getClient(ctx_raw) orelse return ERR_INVALID_ARG;
    const val = c.resetSteward(@intCast(target_cid)) catch |err|
        return mapErr(err);
    if (out_val) |out| out.* = @intCast(val);
    return OK;
}

pub export fn diosix_request_root_failover(
    ctx_raw: ?*anyopaque,
    standby_cid: u64,
    out_val: ?*u64,
) callconv(.c) c_int {
    const c = getClient(ctx_raw) orelse return ERR_INVALID_ARG;
    const val = c.requestRootFailover(@intCast(standby_cid)) catch |err|
        return mapErr(err);
    if (out_val) |out| out.* = @intCast(val);
    return OK;
}

pub export fn diosix_seal_mission(
    ctx_raw: ?*anyopaque,
    in_args: ?*const lib.MissionArgs,
    out_args: ?*lib.MissionArgs,
) callconv(.c) c_int {
    const c = getClient(ctx_raw) orelse return ERR_INVALID_ARG;
    const inp = in_args orelse return ERR_INVALID_ARG;
    const sealed = c.sealMission(inp) catch |err| return mapErr(err);
    if (out_args) |out| out.* = sealed;
    return OK;
}

pub export fn diosix_get_mission(
    ctx_raw: ?*anyopaque,
    proposal_hash_or_null: ?[*]const u8,
    out_args: ?*lib.MissionArgs,
) callconv(.c) c_int {
    const c = getClient(ctx_raw) orelse return ERR_INVALID_ARG;
    const out = out_args orelse return ERR_INVALID_ARG;
    var hash_opt: ?[32]u8 = null;
    if (proposal_hash_or_null) |h| hash_opt = h[0..32].*;
    out.* = c.getMission(hash_opt) catch |err| return mapErr(err);
    return OK;
}

pub export fn diosix_vote_mission(
    ctx_raw: ?*anyopaque,
    proposal_hash_raw: ?[*]const u8,
    decision_raw: u8,
    out_args: ?*lib.MissionVoteArgs,
) callconv(.c) c_int {
    const c = getClient(ctx_raw) orelse return ERR_INVALID_ARG;
    const h = proposal_hash_raw orelse return ERR_INVALID_ARG;
    const dec: lib.MissionVoteDecision = switch (decision_raw) {
        0 => .none,
        1 => .approve,
        2 => .reject,
        else => return ERR_INVALID_ARG,
    };
    const res = c.voteMission(h[0..32].*, dec) catch |err|
        return mapErr(err);
    if (out_args) |out| out.* = res;
    return OK;
}

pub export fn diosix_whisper_send(
    ctx_raw: ?*anyopaque,
    target_cid: u64,
    buf_raw: ?*const anyopaque,
    len: usize,
    out_len: ?*usize,
) callconv(.c) c_int {
    const c = getClient(ctx_raw) orelse return ERR_INVALID_ARG;
    const data = sliceConst(buf_raw, len) orelse return ERR_INVALID_ARG;
    const n = c.whisperSend(@intCast(target_cid), data) catch |err|
        return mapErr(err);
    if (out_len) |out| out.* = n;
    return OK;
}

pub export fn diosix_whisper_recv(
    ctx_raw: ?*anyopaque,
    buf_raw: ?*anyopaque,
    max_len: usize,
    out_len: ?*usize,
) callconv(.c) c_int {
    const c = getClient(ctx_raw) orelse return ERR_INVALID_ARG;
    const buf = sliceMut(buf_raw, max_len) orelse return ERR_INVALID_ARG;
    const n = c.whisperRecv(buf) catch |err| return mapErr(err);
    if (out_len) |out| out.* = n;
    return OK;
}
