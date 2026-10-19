// Diosix hypervisor SBI extension (0x0A000005) handlers.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const riscv = @import("../../hardware/native/cpu/riscv64/mod.zig");
const sv39x4 = @import("../../hardware/native/cpu/riscv64/sv39x4.zig");
const vcore = @import("../vcore.zig");
const guest = @import("../guest.zig");
const scheduler = @import("../scheduler.zig");
const pcore = @import("../pcore.zig");
const physmem = @import("../physmem.zig");
const loader = @import("../loader.zig");
const sbi_core = @import("../sbi.zig");
const charter = @import("charter.zig");
const ipc = @import("ipc.zig");
const interface = @import("interface").sbi;
const arch = @import("interface").riscv;

extern const project_version: [*:0]const u8;
extern const git_branch: [*:0]const u8;
extern const git_revision: [*:0]const u8;
extern const build_date: [*:0]const u8;
extern const build_user: [*:0]const u8;
extern const build_hostname: [*:0]const u8;
extern const zig_version: [*:0]const u8;
extern const cpu_arch: [*:0]const u8;

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
    switch (function) {
        interface.DIOSIX.TERMINATE => handleTerminate(vc, ctx, g, a0, a1),
        interface.DIOSIX.YIELD => {
            if (vc.exec_path == .native) {
                vc.getNativeMachine().mepc +=
                    sbi_core.ECALL_INSTRUCTION_SIZE_BYTES;
            }
            scheduler.yield(vc);
        },
        interface.DIOSIX.DROP_TRUST => {
            g.dropTrust();
            reply(vc, ctx, sbi_core.SBI_SUCCESS, 0);
        },
        interface.DIOSIX.GET_INFO => handleGetInfo(vc, ctx, g, a0, a1, a2),
        interface.DIOSIX.RUN => handleRun(vc, ctx, g, a0),
        interface.DIOSIX.POLL_EVENT => {
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
        interface.DIOSIX.SET_QUOTA => handleSetQuota(vc, ctx, g, a0),
        interface.DIOSIX.GET_HV_INFO => handleGetHvInfo(vc, ctx, g, a0, a1),
        interface.DIOSIX.GET_MANIFEST => ipc.handleGetManifest(vc, ctx, g, a0),
        interface.DIOSIX.SET_MANIFEST => ipc.handleSetManifest(vc, ctx, g, a0),
        interface.DIOSIX.MAP_CHILD_MEM => ipc.handleMapChildMem(vc, ctx, g, a0),
        interface.DIOSIX.UNMAP_CHILD_MEM => {
            ipc.handleUnmapChildMem(vc, ctx, g, a0);
        },
        interface.DIOSIX.START => handleStart(vc, ctx, g, a0),
        interface.DIOSIX.NET_SEND => ipc.handleNetSend(vc, ctx, g, a0, a1, a2),
        interface.DIOSIX.NET_RECV => {
            const max_len = @min(a1, guest.MAX_PACKET_LEN);
            if (g.net_rx.popToGuest(&g.space, a0, max_len)) |copy_len| {
                reply(vc, ctx, sbi_core.SBI_SUCCESS, copy_len);
            } else |_| {
                reply(vc, ctx, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
            }
        },
        interface.DIOSIX.NET_POLL => {
            reply(vc, ctx, sbi_core.SBI_SUCCESS, g.net_rx.getCount());
        },
        interface.DIOSIX.SEAL_CHARTER => {
            charter.handleSealCharter(vc, ctx, a0, a1);
        },
        interface.DIOSIX.RATIFY_CHARTER => {
            charter.handleRatifyCharter(vc, ctx, a0);
        },
        interface.DIOSIX.WHISPER_SEND => {
            charter.handleWhisperSend(vc, ctx, a0, a1, a2);
        },
        interface.DIOSIX.WHISPER_RECV => {
            charter.handleWhisperRecv(vc, ctx, a0, a1);
        },
        interface.DIOSIX.RESET_STEWARD => {
            charter.handleResetSteward(vc, ctx, a0, a1);
        },
        interface.DIOSIX.REQUEST_ROOT_FAILOVER => {
            charter.handleRequestRootFailover(vc, ctx, a0);
        },
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

fn handleGetInfo(
    vc: *VCore,
    ctx: *ThreadCtx,
    g: *Guest,
    a0: usize,
    a1: usize,
    a2: usize,
) void {
    const is_cid = a0 < sbi_core.MAX_USER_CID_DISCRIMINATOR;
    const target_cid = if (is_cid) a0 else 1;
    const info_gpa = if (is_cid) a1 else a0;
    const info_len = if (is_cid) a2 else a1;

    if (info_len != 0 and info_len < @sizeOf(interface.GuestInfo)) {
        reply(vc, ctx, sbi_core.SBI_ERR_INVALID_PARAM, 0);
        return;
    }
    if (target_cid == 0) {
        reply(vc, ctx, sbi_core.SBI_ERR_DENIED, 0);
        return;
    }
    const tg_opt = if (target_cid == 1) g else g.getGuestByCid(target_cid);
    const tg = tg_opt orelse {
        reply(vc, ctx, sbi_core.SBI_ERR_INVALID_PARAM, 0);
        return;
    };

    const max_u = std.math.maxInt(usize);
    const eff_ram: usize = if (tg.space.range_size > 0)
        tg.space.range_size / physmem.PageSize
    else if (tg.is_root)
        sbi_core.DEFAULT_ROOT_RAM_BYTES / physmem.PageSize
    else if (tg.quotas.used_ram_pages > 0 and tg.quotas.used_ram_pages != max_u)
        tg.quotas.used_ram_pages
    else if (tg.quotas.max_ram_pages > 0 and tg.quotas.max_ram_pages != max_u)
        tg.quotas.max_ram_pages
    else
        sbi_core.DEFAULT_CHILD_RAM_BYTES / physmem.PageSize;

    const vcpus = tg.vcores.count();
    const info = interface.GuestInfo{
        .guest_id = if (tg == g) 1 else target_cid,
        .parent_id = if (tg == g)
            (if (g.parent != null) guest.CID_PARENT else 0)
        else
            1,
        .is_trusted = if (tg.is_trusted) 1 else 0,
        .is_root = if (tg.is_root) 1 else 0,
        .target_arch = @backingInt(tg.target_arch),
        .assigned_cid = if (tg.is_root) 1 else @truncate(tg.local_cid),
        .vcpus = vcpus,
        .self_ram_pages = eff_ram,
        .used_vcpus = if (tg.quotas.used_vcpus > 0)
            tg.quotas.used_vcpus
        else
            vcpus,
        .max_vcpus = if (tg.quotas.max_vcpus == max_u)
            vcpus
        else
            tg.quotas.max_vcpus,
        .used_ram_pages = if (tg.quotas.used_ram_pages > 0 and
            tg.quotas.used_ram_pages != max_u)
            tg.quotas.used_ram_pages
        else
            eff_ram,
        .max_ram_pages = if (tg.quotas.max_ram_pages == max_u)
            eff_ram
        else
            tg.quotas.max_ram_pages,
        .child_count = tg.children.count(),
    };

    g.space.writeGuestStruct(interface.GuestInfo, info_gpa, info) catch {
        reply(vc, ctx, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
        return;
    };
    reply(vc, ctx, sbi_core.SBI_SUCCESS, 0);
}

fn handleRun(vc: *VCore, ctx: *ThreadCtx, g: *Guest, a0: usize) void {
    const args = g.space.readGuestStruct(interface.RunArgs, a0) catch {
        reply(vc, ctx, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
        return;
    };
    const want_trusted = (args.flags & interface.RunFlags.TRUSTED) != 0;
    if (want_trusted and !g.is_trusted) {
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
        loader.Loader.detectArchFromGuest(&g.space, elf_ptr, elf_sz) catch null
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

    if (want_trusted) {
        child.is_trusted = true;
        child.space.is_trusted = true;
    } else {
        child.dropTrust();
    }
    child.is_steward = (args.flags & interface.RunFlags.STEWARD) != 0;
    child.is_standby_root =
        (args.flags & interface.RunFlags.STANDBY_ROOT) != 0 and g.is_root;
    child.is_confidential = (args.flags & interface.RunFlags.CONFIDENTIAL) != 0;

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
            if (child.is_steward and (red_ram or red_vcpu) and
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
        };
        reply(vc, ctx, code, 0);
        return;
    };
    reply(vc, ctx, sbi_core.SBI_SUCCESS, 0);
}

fn handleGetHvInfo(
    vc: *VCore,
    ctx: *ThreadCtx,
    g: *Guest,
    buf_gpa: usize,
    buf_len: usize,
) void {
    if (buf_len < @sizeOf(interface.HypervisorInfo)) {
        reply(vc, ctx, sbi_core.SBI_ERR_INVALID_PARAM, 0);
        return;
    }
    var info = interface.HypervisorInfo{};

    const ver_str = std.mem.trim(u8, std.mem.span(project_version), " \t\r\n");
    const parsed_ver = sbi_core.parseVersionString(ver_str);
    info.version_major = parsed_ver.major;
    info.version_minor = parsed_ver.minor;
    info.version_patch = parsed_ver.patch;

    const rev_str = std.mem.trim(u8, std.mem.span(git_revision), " \t\r\n");
    const copy_len = @min(rev_str.len, info.build_commit.len - 1);
    @memcpy(info.build_commit[0..copy_len], rev_str[0..copy_len]);

    const is_stable = (info.version_minor % 2) == 0;
    const channel = if (is_stable) "stable" else "beta";
    info.features = interface.HypervisorFeature.DYNAREC |
        interface.HypervisorFeature.VIRTIO_VSOCK;
    if (is_stable) info.features |= interface.HypervisorFeature.RELEASE_STABLE;
    if (charter.isCharterSealed()) {
        info.features |= interface.HypervisorFeature.CHARTER_SEALED;
    }
    if (!builtin.is_test and riscv.hasHExtension()) {
        info.features |= interface.HypervisorFeature.HARDWARE_VIRT |
            interface.HypervisorFeature.STAGE2_PAGING;
    }

    info.host_physical_cores = riscv.getOnlineCpuCount();
    info.host_timer_freq_hz = interface.HOST_TIMER_FREQ_HZ;
    info.host_total_ram_kb = @intCast(physmem.getTotalRamBytes() / 1024);
    info.host_free_ram_kb = @intCast(physmem.getFreeRamBytes() / 1024);
    info.hv_reserved_bytes = @intCast(physmem.getHvRegion().size);
    info.hv_heap_free_bytes = @intCast(pcore.getTotalFreeHeapBytes());

    _ = std.fmt.bufPrint(
        info.build_desc[0 .. info.build_desc.len - 1],
        "Version {s} ({s}) {s}/{s} {s} {s}@{s} (Zig {s} {s})",
        .{
            ver_str,    channel,        git_branch,  rev_str,  build_date,
            build_user, build_hostname, zig_version, cpu_arch,
        },
    ) catch "";

    const misa = riscv.readMisa();
    var isa_buf: [interface.HOST_CPU_ISA_LEN - 1]u8 = undefined;
    const is_64 = (misa & (@as(usize, 2) << 62)) != 0 or
        builtin.target.cpu.arch == .riscv64;
    const base_str = if (is_64) "RV64" else "RV32";
    @memcpy(isa_buf[0..base_str.len], base_str);
    var isa_len: usize = base_str.len;

    for ("IMAFDCSUH") |ch| {
        const bit = @as(usize, 1) << @intCast(ch - 'A');
        if ((misa & bit) != 0 and isa_len < isa_buf.len) {
            isa_buf[isa_len] = ch;
            isa_len += 1;
        }
    }
    if (isa_len == base_str.len) {
        const fallback = if (is_64) "RV64GC" else "RV32IMAFDC";
        @memcpy(info.host_cpu_isa[0..fallback.len], fallback);
    } else {
        @memcpy(info.host_cpu_isa[0..isa_len], isa_buf[0..isa_len]);
    }

    g.space.writeGuestStruct(interface.HypervisorInfo, buf_gpa, info) catch {
        reply(vc, ctx, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
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
    child.resetForRun(@intCast(sargs.entry_point), @intCast(sargs.dtb_ptr));
    if (child.vcores.start) |vc_node| {
        scheduler.queue(vc_node.contents);
        sbi_core.broadcastPhysicalIPI();
    }
    reply(vc, ctx, sbi_core.SBI_SUCCESS, child.local_cid);
}

test "SBI Diosix hypervisor extension get info and drop trust" {
    const testing = std.testing;
    var phys_test = try physmem.initForTest(testing.allocator, 128);
    defer phys_test.deinit();
    const g = try guest.createGuest(
        testing.allocator,
        true,
        true,
        null,
        0,
        0,
        0,
        .riscv64,
    );
    defer g.deinit();
    var vc = vcore.VirtualCore.init(0, g, 0x80000000, 0, .normal);
    var ctx: riscv.ThreadContext = std.mem.zeroes(riscv.ThreadContext);

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
    const rwx = sv39x4.PTEFlags.read | sv39x4.PTEFlags.write |
        sv39x4.PTEFlags.valid | sv39x4.PTEFlags.accessed |
        sv39x4.PTEFlags.dirty | sv39x4.PTEFlags.user;
    try g.space.map(0x80000000, page_hpa, physmem.PageSize, rwx);
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
