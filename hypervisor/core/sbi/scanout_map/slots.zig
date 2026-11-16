// Stage-2 Zero-Copy Scanout Cache Slot Mapping & Teardown Unmapping
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const riscv = @import("../../../hardware/native/cpu/riscv64/mod.zig");
const sv39x4 = @import("../../../hardware/native/cpu/riscv64/sv39x4.zig");
const guest = @import("../../guest.zig");
const physmem = @import("../../physmem.zig");
const emulation = @import("emulation");
const interface = @import("interface").sbi;

pub fn slotGpa(slot_idx: usize) usize {
    return interface.SCANOUT_MAP_GPA_BASE +
        slot_idx * interface.SCANOUT_SLOT_BYTES;
}

/// Unmaps a single scanout cache slot from `caller` under `scanout_map_lock`.
/// Returns true if any Stage-2 pages were unmapped.
pub fn unmapSlotLocked(caller: *guest.Guest, slot_idx: usize) bool {
    const slot = &caller.scanout_map_slots[slot_idx];
    const pages = slot.page_count;
    slot.* = .{};
    if (pages == 0) return false;
    caller.space.unmap(
        slotGpa(slot_idx),
        @as(usize, pages) * physmem.PageSize,
    );
    return true;
}

fn unmapMatchingChildFromParent(
    parent: *guest.Guest,
    child_guest_id: usize,
) void {
    const s = parent.scanout_map_lock.lock();
    defer parent.scanout_map_lock.unlock(s);

    var any_unmapped = false;
    for (0..interface.SCANOUT_SLOT_COUNT) |i| {
        if (parent.scanout_map_slots[i].child_guest_id == child_guest_id) {
            if (unmapSlotLocked(parent, i)) any_unmapped = true;
        }
    }
    if (any_unmapped) riscv.hfenceGvma();
}

/// Unmaps all Stage-2 zero-copy scanout mappings owned by `g` as well as any
/// parent slots referencing `g` before `g`'s physical RAM is reclaimed.
pub fn unmapOnGuestTeardown(g: *guest.Guest) void {
    {
        const s = g.scanout_map_lock.lock();
        defer g.scanout_map_lock.unlock(s);
        var any_own = false;
        for (0..interface.SCANOUT_SLOT_COUNT) |i| {
            if (unmapSlotLocked(g, i)) any_own = true;
        }
        if (any_own) riscv.hfenceGvma();
    }
    if (g.parent) |p| {
        unmapMatchingChildFromParent(p, g.id);
    }
}

fn pickSlotLocked(caller: *guest.Guest) usize {
    for (0..interface.SCANOUT_SLOT_COUNT) |i| {
        if (caller.scanout_map_slots[i].child_guest_id == 0) return i;
    }
    var best_idx: usize = 0;
    for (1..interface.SCANOUT_SLOT_COUNT) |i| {
        if (caller.scanout_map_slots[i].last_used_seq <
            caller.scanout_map_slots[best_idx].last_used_seq)
        {
            best_idx = i;
        }
    }
    return best_idx;
}

fn rollbackMap(
    base_gpa: usize,
    caller: *guest.Guest,
    mapped_bytes: usize,
) bool {
    if (mapped_bytes > 0) {
        caller.space.unmap(base_gpa, mapped_bytes);
        riscv.hfenceGvma();
    }
    return false;
}

fn mapResourceIntoSlotLocked(
    caller: *guest.Guest,
    target: *guest.Guest,
    slot_idx: usize,
    entries: []const emulation.VirtioGpu.proto_mod.VirtioGpuMemEntry,
    expected_pages: u32,
) bool {
    const base_gpa = slotGpa(slot_idx);
    var mapped_bytes: usize = 0;

    for (entries) |ent| {
        const ent_pages = std.math.divCeil(
            usize,
            ent.length,
            physmem.PageSize,
        ) catch return rollbackMap(base_gpa, caller, mapped_bytes);
        var pg: usize = 0;
        while (pg < ent_pages) : (pg += 1) {
            const child_gpa = ent.addr + pg * physmem.PageSize;
            const hpa = target.space.translateGPA(child_gpa) catch {
                return rollbackMap(base_gpa, caller, mapped_bytes);
            };
            if (physmem.isHypervisorMemory(hpa, physmem.PageSize) or
                !physmem.isRam(hpa, physmem.PageSize))
            {
                return rollbackMap(base_gpa, caller, mapped_bytes);
            }
            caller.space.map(
                base_gpa + mapped_bytes,
                hpa,
                physmem.PageSize,
                sv39x4.PTEFlags.leaf_ro_user,
            ) catch return rollbackMap(base_gpa, caller, mapped_bytes);
            mapped_bytes += physmem.PageSize;
        }
    }

    if (mapped_bytes != @as(usize, expected_pages) * physmem.PageSize) {
        return rollbackMap(base_gpa, caller, mapped_bytes);
    }
    return true;
}

/// Finds a matching read-only Stage-2 scanout cache slot or maps `res` via LRU.
pub fn findOrMapZeroCopyLocked(
    caller: *guest.Guest,
    target: *guest.Guest,
    res: *const emulation.VirtioGpu.proto_mod.VirtioGpuResource,
    page_count: u32,
) ?usize {
    for (0..interface.SCANOUT_SLOT_COUNT) |i| {
        const slot = &caller.scanout_map_slots[i];
        if (slot.child_guest_id == target.id and
            slot.res_id == res.id and
            slot.backing_gen == res.backing_gen and
            slot.page_count == page_count)
        {
            caller.scanout_lru_clock +%= 1;
            slot.last_used_seq = caller.scanout_lru_clock;
            return i;
        }
    }

    const chosen = pickSlotLocked(caller);
    const old_unmapped = unmapSlotLocked(caller, chosen);
    if (!mapResourceIntoSlotLocked(
        caller,
        target,
        chosen,
        res.entriesSlice(),
        page_count,
    )) {
        if (old_unmapped) riscv.hfenceGvma();
        return null;
    }

    caller.scanout_lru_clock +%= 1;
    caller.scanout_map_slots[chosen] = .{
        .child_guest_id = target.id,
        .res_id = res.id,
        .backing_gen = res.backing_gen,
        .page_count = page_count,
        .last_used_seq = caller.scanout_lru_clock,
    };
    riscv.hfenceGvma();
    return chosen;
}
