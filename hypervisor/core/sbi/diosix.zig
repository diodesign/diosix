// Diosix hypervisor SBI extension (0x0a000005) handlers.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const riscv = @import("../../hardware/native/cpu/riscv64/mod.zig");
const sv39x4 = @import("../../hardware/native/cpu/riscv64/sv39x4.zig");
const vcore = @import("../vcore.zig");
const guest = @import("../guest.zig");
const scheduler = @import("../scheduler.zig");
const physmem = @import("../physmem.zig");
const loader = @import("../loader.zig");
const sbi_core = @import("../sbi.zig");
const charter = @import("charter.zig");
const ipc = @import("ipc.zig");
const console = @import("console.zig");
const info = @import("info.zig");
const interface = @import("interface").sbi;
const arch = @import("interface").riscv;

pub const handleGetInfo = info.handleGetInfo;
pub const handleGetHvInfo = info.handleGetHvInfo;
pub const formatIsaString = info.formatIsaString;

const VCore = vcore.VirtualCore;
const ThreadCtx = riscv.ThreadContext;
const Guest = guest.Guest;

inline fn reply(vc: *VCore, ctx: *ThreadCtx, err: isize, val: usize) void {
    sbi_core.setResult(vc, ctx, err, val);
}

pub fn handleDiosix(
    vc: *VCore,
    ctx: *ThreadCtx,
    function: usize,
    a0: usize,
    a1: usize,
    a2: usize,
) void {
    const g = vc.getGuest();
    const D = interface.DIOSIX;
    switch (function) {
        D.TERMINATE => handleTerminate(vc, ctx, g, a0, a1),
        D.YIELD => {
            if (vc.exec_path == .native) {
                vc.getNativeMachine().mepc +=
                    sbi_core.ECALL_INSTRUCTION_SIZE_BYTES;
            }
            scheduler.yield(vc);
        },
        D.DROP_TRUST => {
            g.dropTrust();
            reply(vc, ctx, sbi_core.SBI_SUCCESS, 0);
        },
        D.GET_INFO => handleGetInfo(vc, ctx, g, a0, a1, a2),
        D.RUN => handleRun(vc, ctx, g, a0),
        D.POLL_EVENT => {
            if (a1 < @sizeOf(interface.Event)) {
                reply(vc, ctx, sbi_core.SBI_ERR_INVALID_PARAM, 0);
                return;
            }
            if (g.events.popIfWritten(a2, g, a0)) |found| {
                reply(vc, ctx, sbi_core.SBI_SUCCESS, if (found) 1 else 0);
            } else |_| {
                reply(vc, ctx, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
            }
        },
        D.SET_QUOTA => handleSetQuota(vc, ctx, g, a0),
        D.GET_HV_INFO => handleGetHvInfo(vc, ctx, g, a0, a1),
        D.GET_MANIFEST => ipc.handleGetManifest(vc, ctx, g, a0),
        D.SET_MANIFEST => ipc.handleSetManifest(vc, ctx, g, a0),
        D.MAP_CHILD_MEM => ipc.handleMapChildMem(vc, ctx, g, a0),
        D.UNMAP_CHILD_MEM => ipc.handleUnmapChildMem(vc, ctx, g, a0),
        D.START => handleStart(vc, ctx, g, a0),
        D.NET_SEND => ipc.handleNetSend(vc, ctx, g, a0, a1, a2),
        D.NET_RECV => {
            const max_len: usize = @min(a1, guest.MAX_PACKET_LEN);
            if (g.net_rx.popToGuest(&g.space, a0, max_len)) |copy_len| {
                reply(vc, ctx, sbi_core.SBI_SUCCESS, copy_len);
            } else |_| {
                reply(vc, ctx, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
            }
        },
        D.NET_POLL => reply(vc, ctx, sbi_core.SBI_SUCCESS, g.net_rx.getCount()),
        D.SEAL_CHARTER => charter.handleSealCharter(vc, ctx, a0, a1),
        D.RATIFY_CHARTER => charter.handleRatifyCharter(vc, ctx, a0),
        D.WHISPER_SEND => charter.handleWhisperSend(vc, ctx, a0, a1, a2),
        D.WHISPER_RECV => charter.handleWhisperRecv(vc, ctx, a0, a1),
        D.RESET_STEWARD => charter.handleResetSteward(vc, ctx, a0, a1),
        D.REQUEST_ROOT_FAILOVER => {
            charter.handleRequestRootFailover(vc, ctx, a0);
        },
        D.CONSOLE_WRITE => console.handleConsoleWrite(vc, ctx, g, a0),
        D.CONSOLE_READ => console.handleConsoleRead(vc, ctx, g, a0),
        else => reply(vc, ctx, sbi_core.SBI_ERR_NOT_SUPPORTED, 0),
    }
}

fn handleTerminate(
    vc: *VCore,
    ctx: *ThreadCtx,
    g: *Guest,
    target_cid: usize,
    exit_code: usize,
) void {
    if (target_cid == guest.CID_SELF or
        (target_cid == guest.CID_PARENT and g.is_root))
    {
        sbi_core.terminateOrRestart(g, exit_code);
    } else if (target_cid == guest.CID_PARENT) {
        reply(vc, ctx, sbi_core.SBI_ERR_DENIED, 0);
    } else if (target_cid >= guest.CID_FIRST_CHILD) {
        if (g.getGuestByCid(target_cid)) |child| {
            const ok = !child.is_steward or
                charter.checkAndConsumeQuorum(target_cid);
            if (!ok) {
                reply(vc, ctx, sbi_core.SBI_ERR_DENIED, 0);
                return;
            }
            child.terminateWithCode(exit_code);
            child.deinit();
            reply(vc, ctx, sbi_core.SBI_SUCCESS, 0);
        } else {
            reply(vc, ctx, sbi_core.SBI_ERR_INVALID_PARAM, 0);
        }
    } else {
        reply(vc, ctx, sbi_core.SBI_ERR_INVALID_PARAM, 0);
    }
}

fn handleRun(vc: *VCore, ctx: *ThreadCtx, g: *Guest, a0: usize) void {
    const args = g.space.readGuestStruct(interface.RunArgs, a0) catch {
        reply(vc, ctx, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
        return;
    };
    const want_trusted = (args.flags & interface.RunFlags.TRUSTED) != 0;
    const want_steward = (args.flags & interface.RunFlags.STEWARD) != 0;
    if ((want_trusted and !g.is_trusted) or
        (want_steward and (!g.is_root or charter.isCharterSealed())))
    {
        reply(vc, ctx, sbi_core.SBI_ERR_DENIED, 0);
        return;
    }
    const elf_ptr: usize = @intCast(args.elf_ptr);
    const elf_sz: usize = @intCast(args.elf_size);
    if (elf_sz > sbi_core.MAX_FOREIGN_MAP_SIZE_BYTES) {
        reply(vc, ctx, sbi_core.SBI_ERR_INVALID_PARAM, 0);
        return;
    }
    if (elf_sz > 0) {
        _ = std.math.add(usize, elf_ptr, elf_sz) catch {
            reply(vc, ctx, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
            return;
        };
    }

    const detected_arch: ?guest.TargetArch = if (elf_sz > 0)
        loader.Loader.detectArchFromGuest(&g.space, elf_ptr, elf_sz) catch |e| {
            const code = if (e == loader.LoaderError.TranslationFailed)
                sbi_core.SBI_ERR_INVALID_ADDRESS
            else
                sbi_core.SBI_ERR_FAILED;
            reply(vc, ctx, code, 0);
            return;
        }
    else
        null;

    const created_new = (args.child_id == 0);
    const child = (if (args.child_id >= guest.CID_FIRST_CHILD)
        g.getGuestByCid(args.child_id)
    else if (created_new)
        g.createChild(want_trusted, detected_arch orelse .riscv64, 1) catch null
    else
        null) orelse {
        reply(vc, ctx, sbi_core.SBI_ERR_INVALID_PARAM, 0);
        return;
    };

    if (!created_new) {
        if (child.is_confidential and child.hasAnyVcoreStarted()) {
            reply(vc, ctx, sbi_core.SBI_ERR_DENIED, 0);
            return;
        }
        if (child.is_steward and charter.isCharterSealed() and
            !charter.checkAndConsumeQuorum(child.local_cid))
        {
            reply(vc, ctx, sbi_core.SBI_ERR_DENIED, 0);
            return;
        }
    }

    if (want_trusted) {
        child.is_trusted = true;
        child.space.is_trusted = true;
    } else {
        child.dropTrust();
    }
    child.is_steward = child.is_steward or want_steward;
    child.is_standby_root = child.is_standby_root or
        ((args.flags & interface.RunFlags.STANDBY_ROOT) != 0 and g.is_root);
    child.is_confidential = child.is_confidential or child.is_steward or
        ((args.flags & interface.RunFlags.CONFIDENTIAL) != 0);

    child.stop();
    if (riscv.hasHExtension()) riscv.hfenceGvma() else riscv.sfenceVma();

    if (elf_sz == 0) {
        reply(vc, ctx, sbi_core.SBI_SUCCESS, child.local_cid);
        return;
    }
    if (detected_arch) |da| child.target_arch = da;

    const entry_point = loader.Loader.loadFromGuest(
        child,
        &g.space,
        elf_ptr,
        elf_sz,
    ) catch |err| {
        if (created_new) {
            child.terminate();
            child.deinit();
        }
        const err_code = if (err == loader.LoaderError.TranslationFailed)
            sbi_core.SBI_ERR_INVALID_ADDRESS
        else
            sbi_core.SBI_ERR_FAILED;
        reply(vc, ctx, err_code, 0);
        return;
    };

    child.resetForRun(entry_point, @intCast(args.dtb_ptr));
    if (child.vcores.start) |vc_node| scheduler.queue(vc_node.contents);
    reply(vc, ctx, sbi_core.SBI_SUCCESS, child.local_cid);
}

fn handleSetQuota(vc: *VCore, ctx: *ThreadCtx, g: *Guest, a0: usize) void {
    const qargs = g.space.readGuestStruct(interface.QuotaArgs, a0) catch {
        reply(vc, ctx, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
        return;
    };
    const t_cid: usize = @intCast(qargs.target_cid);
    if (t_cid >= guest.CID_FIRST_CHILD) {
        if (g.getGuestByCid(t_cid)) |child| {
            const red_ram = qargs.max_ram_pages > 0 and
                qargs.max_ram_pages < child.quotas.max_ram_pages;
            const red_vcpu = qargs.max_vcpus > 0 and
                qargs.max_vcpus < child.quotas.max_vcpus;
            const red_pcpu = qargs.pcpu_quota_pct > 0 and
                qargs.pcpu_quota_pct < child.quotas.pcpu_quota_pct;
            if (child.is_steward and (red_ram or red_vcpu or red_pcpu) and
                !charter.checkAndConsumeQuorum(t_cid))
            {
                reply(vc, ctx, sbi_core.SBI_ERR_DENIED, 0);
                return;
            }
        }
    }
    g.setQuota(qargs) catch |err| {
        const code = switch (err) {
            error.AccessDenied => sbi_core.SBI_ERR_DENIED,
            error.InvalidParam => sbi_core.SBI_ERR_INVALID_PARAM,
            error.OutOfMemory => sbi_core.SBI_ERR_FAILED,
        };
        reply(vc, ctx, code, 0);
        return;
    };
    reply(vc, ctx, sbi_core.SBI_SUCCESS, 0);
}

fn handleStart(vc: *VCore, ctx: *ThreadCtx, g: *Guest, a0: usize) void {
    const sargs = g.space.readGuestStruct(interface.StartArgs, a0) catch {
        reply(vc, ctx, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
        return;
    };
    if ((sargs.entry_point & 1) != 0 or (sargs.dtb_ptr & 3) != 0) {
        reply(vc, ctx, sbi_core.SBI_ERR_INVALID_PARAM, 0);
        return;
    }
    const child = g.getGuestByCid(@intCast(sargs.child_id)) orelse {
        reply(vc, ctx, sbi_core.SBI_ERR_INVALID_PARAM, 0);
        return;
    };
    if (!g.is_trusted and !g.is_root and child.parent != g) {
        reply(vc, ctx, sbi_core.SBI_ERR_DENIED, 0);
        return;
    }
    if ((child.is_steward and charter.isCharterSealed()) or
        (child.is_confidential and child.hasAnyVcoreStarted()))
    {
        reply(vc, ctx, sbi_core.SBI_ERR_DENIED, 0);
        return;
    }
    child.stop();
    if (riscv.hasHExtension()) riscv.hfenceGvma() else riscv.sfenceVma();
    const entry: usize = if (sargs.entry_point != 0)
        @intCast(sargs.entry_point)
    else
        child.initial_entry_point;
    const dtb: usize = if (sargs.dtb_ptr != 0 or sargs.entry_point != 0)
        @intCast(sargs.dtb_ptr)
    else
        child.initial_dtb_ptr;
    child.resetForRun(entry, dtb);
    if (child.vcores.start) |vc_node| {
        scheduler.queue(vc_node.contents);
    }
    reply(vc, ctx, sbi_core.SBI_SUCCESS, child.local_cid);
}

test "SBI Diosix hypervisor extension get info and drop trust" {
    std.testing.refAllDecls(@This());
    const testing = std.testing;
    const alloc = testing.allocator;
    var phys_test = try physmem.initForTest(alloc, 128);
    defer phys_test.deinit();
    const g = try guest.createGuest(alloc, true, true, null, 0, 0, 0, .riscv64);
    defer g.deinit();
    var vc = vcore.VirtualCore.init(0, g, 0x80000000, 0, .normal);
    var ctx: riscv.ThreadContext = @splat(0);

    try testing.expect(g.is_trusted);
    ctx[@backingInt(arch.Register.a7)] = interface.EXT.DIOSIX;
    ctx[@backingInt(arch.Register.a6)] = interface.DIOSIX.DROP_TRUST;
    sbi_core.handle(&vc, 0, &ctx);
    const a0_idx = @backingInt(arch.Register.a0);
    try testing.expectEqual(@as(usize, 0), ctx[a0_idx]);
    try testing.expect(!g.is_trusted);

    ctx[@backingInt(arch.Register.a6)] = interface.DIOSIX.GET_HV_INFO;
    ctx[a0_idx] = 0x80000000;
    ctx[@backingInt(arch.Register.a1)] = @sizeOf(interface.HypervisorInfo) - 1;
    sbi_core.handle(&vc, 0, &ctx);
    const inv_param: usize = @bitCast(sbi_core.SBI_ERR_INVALID_PARAM);
    try testing.expectEqual(inv_param, ctx[a0_idx]);

    const page_hpa = try physmem.allocPage();
    const rw = sv39x4.PTEFlags.leaf_rw_user;
    try g.space.map(0x80000000, page_hpa, physmem.PageSize, rw);
    physmem.decrementPageRef(page_hpa);

    ctx[a0_idx] = 0x80000000;
    ctx[@backingInt(arch.Register.a1)] = @sizeOf(interface.HypervisorInfo);
    sbi_core.handle(&vc, 0, &ctx);
    try testing.expectEqual(@as(usize, 0), ctx[a0_idx]);
    const HvInfo = interface.HypervisorInfo;
    const hv_info = try g.space.readGuestStruct(HvInfo, 0x80000000);
    try testing.expectEqual(@as(u16, 26), hv_info.version_major);
    const build_desc = std.mem.sliceTo(&hv_info.build_desc, 0);
    try testing.expect(std.mem.indexOf(u8, build_desc, "(beta)") != null or
        std.mem.indexOf(u8, build_desc, "(stable)") != null);
    const last_idx = hv_info.build_commit.len - 1;
    try testing.expectEqual(@as(u8, 0), hv_info.build_commit[last_idx]);
}
