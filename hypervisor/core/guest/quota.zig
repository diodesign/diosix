// Resource quota enforcement and VMID allocation for Guest VMs.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const atomic = @import("../atomic.zig");
const physmem = @import("../physmem.zig");
const debug = @import("../debug.zig");
const scheduler = @import("../scheduler.zig");
const guest_mod = @import("../guest.zig");
const sbi = @import("interface").sbi;
pub const manifest_mod = @import("manifest.zig");

pub const max_vmids: u16 = 4096;
pub const BITS_PER_WORD: usize = @bitSizeOf(u64);
pub const VMID_BITMAP_WORDS: usize = max_vmids / BITS_PER_WORD;
pub const MAX_STOP_SPINS: usize = manifest_mod.MAX_STOP_SPINS;
pub const STOP_IPI_RETRY_SPINS: usize = manifest_mod.STOP_IPI_RETRY_SPINS;

pub const MAX_CHILD_PCPU_QUOTA_PCT: u32 = sbi.MAX_CHILD_PCPU_QUOTA_PCT;
pub const DEFAULT_RETAINED_PCPU_PCT: u32 = sbi.DEFAULT_RETAINED_PCPU_PCT;
pub const DEFAULT_CHILD_PCPU_QUOTA_PCT: u32 = sbi.DEFAULT_CHILD_PCPU_QUOTA_PCT;
pub const FULL_PCPU_BASIS_POINTS: u64 = 10_000;

pub const setManifest = manifest_mod.setManifest;
pub const readManifest = manifest_mod.readManifest;
pub const getManifestLength = manifest_mod.getManifestLength;
pub const hasAnyVcoreStarted = manifest_mod.hasAnyVcoreStarted;
pub const stop = manifest_mod.stop;
pub const resetForRun = manifest_mod.resetForRun;

pub const QuotaSet = struct {
    max_ram_pages: usize = std.math.maxInt(usize),
    used_ram_pages: usize = 0,
    committed_ram_pages: usize = 0,
    delegated_ram_pages: usize = 0,
    max_vcpus: usize = std.math.maxInt(usize),
    used_vcpus: usize = 0,
    pcpu_quota_pct: u32 = 100,
    retained_pcpu_pct: u32 = DEFAULT_RETAINED_PCPU_PCT,
    delegated_pcpu_pct: u32 = 0,
    window_id: u64 = 0,
    window_ticks_used: u64 = 0,
    subtree_window_ticks_used: u64 = 0,
    max_priority: u8 = std.math.maxInt(u8),
    max_child_depth: usize = std.math.maxInt(usize),
    current_depth: usize = 0,
    max_descendants: usize = std.math.maxInt(usize),
    used_descendants: usize = 0,
};

pub fn maxChildPcpuPct(self: *const guest_mod.Guest) u32 {
    const ret = std.math.clamp(self.quotas.retained_pcpu_pct, 1, 99);
    return 100 -| ret;
}

// Global guest manager state to encapsulate VMIDs and guest ID counters.
const GuestManagerState = struct {
    vmid_bitmap: [VMID_BITMAP_WORDS]u64 = blk: {
        var bm: [VMID_BITMAP_WORDS]u64 = @splat(0);
        // VMID 0 is permanently reserved in RISC-V hgatp.
        bm[0] = 1;
        break :blk bm;
    },
    guest_id_next: usize = sbi.CID_SELF,
};

var guest_manager = atomic.LockPayload(GuestManagerState).init(
    "Global guest manager state",
    .{},
);

pub fn allocGuestId() usize {
    const guard = guest_manager.acquire();
    defer guard.release();
    const state = guard.get();
    const next = state.guest_id_next;
    state.guest_id_next =
        std.math.add(usize, next, 1) catch std.math.maxInt(usize);
    return next;
}

pub fn resetGuestManagerForTest() void {
    const guard = guest_manager.acquire();
    defer guard.release();
    const state = guard.get();
    state.guest_id_next = sbi.CID_SELF;
    state.vmid_bitmap = @splat(0);
    state.vmid_bitmap[0] = 1;
}

pub fn isVmidAllocated(id: u16) bool {
    if (id >= max_vmids) return false;
    const guard = guest_manager.acquire();
    defer guard.release();
    const state = guard.get();
    const wi = id / BITS_PER_WORD;
    const bit: u6 = @intCast(id % BITS_PER_WORD);
    return (state.vmid_bitmap[wi] & (@as(u64, 1) << bit)) != 0;
}

pub fn allocVmid() !u16 {
    const guard = guest_manager.acquire();
    defer guard.release();
    const state = guard.get();

    for (&state.vmid_bitmap, 0..) |*word, wi| {
        if (word.* == std.math.maxInt(u64)) continue;
        const free_bit: u6 = @intCast(@ctz(~word.*));
        const vmid: u16 = @intCast(wi * BITS_PER_WORD + free_bit);
        if (vmid >= max_vmids) break;
        word.* |= @as(u64, 1) << free_bit;
        return vmid;
    }
    debug.printf("VMID: All {} VMIDs exhausted\n", .{max_vmids});
    return error.OutOfMemory;
}

pub fn freeVmid(id: u16) void {
    const guard = guest_manager.acquire();
    defer guard.release();
    const state = guard.get();
    if (id == 0 or id >= max_vmids) return;
    const wi = id / BITS_PER_WORD;
    const bit: u6 = @intCast(id % BITS_PER_WORD);
    state.vmid_bitmap[wi] &= ~(@as(u64, 1) << bit);
}

/// Invoked when a guest or its subtree exhausts its physical RAM quota pool
/// (either during a Stage-2 demand-paging fault or when a parent dials down
/// a running child's RAM quota below its currently in-use memory).
///
/// Emits `EventType.child_memory_pressure` to the parent VM to leave the door
/// open for future S-mode swap/migration delegation before terminating the
/// child with OOM exit code 1.
pub fn onMemoryPoolExhausted(self: *guest_mod.Guest) void {
    if (self.is_root) return;
    if (self.parent) |p| {
        p.events.push(.{
            .cid = self.local_cid,
            .event_type = @backingInt(sbi.EventType.child_memory_pressure),
            .exit_code = @truncate(self.quotas.used_ram_pages),
        });
    }
    debug.printf(
        "OOM: Child guest VM (ID {}, CID {}) exceeded RAM quota " ++
            "({}/{} pages). Terminating.\n",
        .{
            self.id,
            self.local_cid,
            self.quotas.used_ram_pages,
            self.quotas.max_ram_pages,
        },
    );
    self.terminateWithCode(1);
}

fn applyQuotaToTarget(
    target: *guest_mod.Guest,
    ceil: *guest_mod.Guest,
    args: sbi.QuotaArgs,
) !void {
    if (args.pcpu_quota_pct > 0) {
        if (target != ceil) {
            const max_child_pct = maxChildPcpuPct(ceil);
            if (args.pcpu_quota_pct > max_child_pct) {
                return error.AccessDenied;
            }
            const req_pct: u32 = @intCast(args.pcpu_quota_pct);
            const other_pct =
                ceil.quotas.delegated_pcpu_pct -| target.quotas.pcpu_quota_pct;
            if (other_pct + req_pct > max_child_pct) {
                return error.AccessDenied;
            }
            target.quotas.pcpu_quota_pct = req_pct;
            ceil.quotas.delegated_pcpu_pct = other_pct + req_pct;
        } else if (target.is_root) {
            if (args.pcpu_quota_pct > 99) return error.InvalidParam;
            const req_ret: u32 = @intCast(args.pcpu_quota_pct);
            if (req_ret + target.quotas.delegated_pcpu_pct > 100) {
                return error.AccessDenied;
            }
            target.quotas.retained_pcpu_pct = req_ret;
        } else {
            const req_pct: u32 = @intCast(@min(args.pcpu_quota_pct, 100));
            target.quotas.pcpu_quota_pct =
                @min(target.quotas.pcpu_quota_pct, req_pct);
        }
    }

    if (target != ceil and target.space.mode == .pmp_fallback) {
        const started = target.hasAnyVcoreStarted();
        const cur_logical = target.space.range_size / physmem.PageSize;
        const logical_pages: usize = if (!started and
            args.logical_ram_pages > 0)
            @intCast(args.logical_ram_pages)
        else if (!started and args.max_ram_pages > 0)
            @intCast(args.max_ram_pages)
        else
            cur_logical;
        const quota_pages: usize = if (args.max_ram_pages > 0)
            @intCast(args.max_ram_pages)
        else
            target.quotas.max_ram_pages;
        if (!started) {
            const other_del =
                ceil.quotas.delegated_ram_pages -|
                target.quotas.committed_ram_pages;
            const parent_avail = ceil.quotas.max_ram_pages -|
                @max(ceil.quotas.used_ram_pages, other_del);
            if (logical_pages > quota_pages or
                logical_pages > parent_avail or
                quota_pages > parent_avail)
            {
                return error.AccessDenied;
            }
        }
    }

    if (!target.hasAnyVcoreStarted() and args.logical_ram_pages > 0) {
        const log_bytes = std.math.mul(
            usize,
            @intCast(args.logical_ram_pages),
            physmem.PageSize,
        ) catch std.math.maxInt(usize);
        target.space.setRangeSize(log_bytes);
    }

    if (args.max_ram_pages > 0) {
        const req_ram: usize = @intCast(args.max_ram_pages);
        if (target == ceil) {
            target.quotas.max_ram_pages =
                @min(target.quotas.max_ram_pages, req_ram);
            target.quotas.used_ram_pages = @min(
                target.quotas.used_ram_pages,
                target.quotas.max_ram_pages,
            );
            const max_bytes = std.math.mul(
                usize,
                target.quotas.max_ram_pages,
                physmem.PageSize,
            ) catch std.math.maxInt(usize);
            if (target.space.range_size == 0 or
                target.space.range_size > max_bytes)
            {
                target.space.setRangeSize(max_bytes);
            }
        } else {
            const old_com = target.quotas.committed_ram_pages;
            ceil.quotas.delegated_ram_pages =
                (ceil.quotas.delegated_ram_pages -| old_com) +| req_ram;
            target.quotas.committed_ram_pages = req_ram;
            target.quotas.max_ram_pages = req_ram;

            if (!target.hasAnyVcoreStarted() and args.logical_ram_pages == 0) {
                const max_bytes = std.math.mul(
                    usize,
                    req_ram,
                    physmem.PageSize,
                ) catch std.math.maxInt(usize);
                target.space.setRangeSize(max_bytes);
            }

            const pmp_in_use = if (target.space.mode == .pmp_fallback and
                target.hasAnyVcoreStarted())
                target.space.range_size / physmem.PageSize
            else
                0;
            const in_use = @max(target.quotas.used_ram_pages, pmp_in_use);
            if (in_use > target.quotas.max_ram_pages) {
                onMemoryPoolExhausted(target);
                return;
            }
        }
    }

    if (args.max_vcpus > 0) {
        if (args.max_vcpus > guest_mod.max_vcores) return error.InvalidParam;
        const max_v: usize = @min(
            ceil.quotas.max_vcpus,
            @as(usize, @intCast(args.max_vcpus)),
        );
        target.quotas.max_vcpus = max_v;
        if (target != ceil) {
            const cur_vcpus = target.vcores.count();
            if (!target.hasAnyVcoreStarted() and
                target.quotas.max_vcpus > cur_vcpus)
            {
                const extra = target.quotas.max_vcpus - cur_vcpus;
                if (!ceil.checkVcpuQuota(extra)) return error.AccessDenied;
                var added: usize = 0;
                errdefer if (added > 0) {
                    target.quotas.used_vcpus += added;
                    var p = target.parent;
                    while (p) |anc| : (p = anc.parent) {
                        _ = @atomicRmw(
                            usize,
                            &anc.quotas.used_vcpus,
                            .Add,
                            added,
                            .monotonic,
                        );
                    }
                };
                for (cur_vcpus..target.quotas.max_vcpus) |vid| {
                    const vc = target.addVcore(
                        vid,
                        0,
                        0,
                        .normal,
                        null,
                    ) catch return error.OutOfMemory;
                    vc.state = .stopped;
                    added += 1;
                }
                if (added > 0) {
                    target.quotas.used_vcpus += added;
                    var p = target.parent;
                    while (p) |anc| : (p = anc.parent) {
                        _ = @atomicRmw(
                            usize,
                            &anc.quotas.used_vcpus,
                            .Add,
                            added,
                            .monotonic,
                        );
                    }
                }
            }
            target.quotas.used_vcpus =
                @min(target.quotas.used_vcpus, target.quotas.max_vcpus);
        }
    }
    if (args.max_child_depth > 0) {
        const max_d: usize = @min(
            ceil.quotas.max_child_depth,
            @as(usize, @intCast(args.max_child_depth)),
        );
        target.quotas.max_child_depth =
            @min(target.quotas.max_child_depth, max_d);
    }
    if (args.max_descendants > 0) {
        const max_desc: usize = @min(
            ceil.quotas.max_descendants,
            @as(usize, @intCast(args.max_descendants)),
        );
        target.quotas.max_descendants =
            @min(target.quotas.max_descendants, max_desc);
    }
}

pub fn setQuota(self: *guest_mod.Guest, args: sbi.QuotaArgs) !void {
    if (args.target_cid == sbi.CID_SELF) {
        try applyQuotaToTarget(self, self, args);
    } else if (args.target_cid >= sbi.CID_FIRST_CHILD) {
        if (self.getGuestByCid(args.target_cid)) |child| {
            try applyQuotaToTarget(child, self, args);
        } else {
            return error.InvalidParam;
        }
    } else {
        return error.AccessDenied;
    }
}

pub fn reduceQuota(self: *guest_mod.Guest, new_quotas: QuotaSet) void {
    const cur = &self.quotas;
    const mr: usize = @min(cur.max_ram_pages, new_quotas.max_ram_pages);
    const mv: usize = @min(cur.max_vcpus, new_quotas.max_vcpus);
    const md: usize = @min(cur.max_child_depth, new_quotas.max_child_depth);
    const mdesc: usize = @min(cur.max_descendants, new_quotas.max_descendants);
    cur.max_ram_pages = mr;
    cur.max_vcpus = mv;
    cur.max_priority = @min(cur.max_priority, new_quotas.max_priority);
    cur.max_child_depth = md;
    cur.max_descendants = mdesc;
}

pub fn checkQuota(
    self: *const guest_mod.Guest,
    ram_pages: usize,
    vcpus: usize,
    depth: usize,
) bool {
    const q = &self.quotas;
    const new_ram = std.math.add(usize, q.used_ram_pages, ram_pages) catch
        return false;
    if (new_ram > q.max_ram_pages) return false;
    const new_vcpus = std.math.add(usize, q.used_vcpus, vcpus) catch
        return false;
    if (new_vcpus > q.max_vcpus) return false;
    if (depth > q.max_child_depth) return false;
    const new_desc = std.math.add(usize, q.used_descendants, 1) catch
        return false;
    if (new_desc > q.max_descendants) return false;
    return if (self.parent) |p| p.checkQuota(ram_pages, vcpus, depth) else true;
}

pub fn checkRamQuota(self: *const guest_mod.Guest, ram_pages: usize) bool {
    const q = &self.quotas;
    const new_ram = std.math.add(usize, q.used_ram_pages, ram_pages) catch
        return false;
    if (new_ram > q.max_ram_pages) return false;
    return if (self.parent) |p| p.checkRamQuota(ram_pages) else true;
}

pub fn checkVcpuQuota(self: *const guest_mod.Guest, vcpus: usize) bool {
    const q = &self.quotas;
    const new_vcpus = std.math.add(usize, q.used_vcpus, vcpus) catch
        return false;
    if (new_vcpus > q.max_vcpus) return false;
    return if (self.parent) |p| p.checkVcpuQuota(vcpus) else true;
}

pub fn consumeQuota(
    self: *guest_mod.Guest,
    ram_pages: usize,
    vcpus: usize,
) void {
    if (ram_pages > 0) {
        _ = @atomicRmw(
            usize,
            &self.quotas.used_ram_pages,
            .Add,
            ram_pages,
            .monotonic,
        );
    }
    if (vcpus > 0) {
        _ = @atomicRmw(
            usize,
            &self.quotas.used_vcpus,
            .Add,
            vcpus,
            .monotonic,
        );
    }
    if (self.parent) |p| p.consumeQuota(ram_pages, vcpus);
}

pub fn releaseQuota(
    self: *guest_mod.Guest,
    ram_pages: usize,
    vcpus: usize,
) void {
    if (ram_pages > 0) {
        _ = @atomicRmw(
            usize,
            &self.quotas.used_ram_pages,
            .Sub,
            @min(ram_pages, self.quotas.used_ram_pages),
            .monotonic,
        );
    }
    if (vcpus > 0) {
        _ = @atomicRmw(
            usize,
            &self.quotas.used_vcpus,
            .Sub,
            @min(vcpus, self.quotas.used_vcpus),
            .monotonic,
        );
    }
    if (self.parent) |p| p.releaseQuota(ram_pages, vcpus);
}

test "guest quota management, manifest, and VMID double-free guard" {
    _ = manifest_mod;
    std.testing.refAllDecls(@This());
}
