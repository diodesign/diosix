// RISC-V Supervisor Binary Interface (SBI) implementation.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const riscv = @import("../hardware/native/cpu/riscv64/mod.zig");
const vcore = @import("vcore.zig");
const guest = @import("guest.zig");
const debug = @import("debug.zig");
const scheduler = @import("scheduler.zig");
const pcore = @import("pcore.zig");
const physmem = @import("physmem.zig");
const interface = @import("interface").sbi;
const arch = @import("interface").riscv;
const config = @import("config");
const charter = @import("sbi/charter.zig");
const diosix_sbi = @import("sbi/diosix.zig");
const standard = @import("sbi/standard.zig");

pub const MAX_STEWARD_QUORUM_TOTAL = charter.MAX_STEWARD_QUORUM_TOTAL;
pub const CharterState = charter.CharterState;
pub const resetCharterForTest = charter.resetCharterForTest;
pub const isCharterSealed = charter.isCharterSealed;

pub const RV32_WORD_MASK: u64 = 0xffff_ffff;
pub const RV32_HIGH_SHIFT: u6 = 32;
pub const ECALL_INSTRUCTION_SIZE_BYTES: usize = 4;
pub const MIP_SSIP_BIT: u6 = arch.MIP.SSIP_BIT;
pub const MIP_STIP_BIT: u6 = arch.MIP.STIP_BIT;
pub const DBCN_CHUNK_BUFFER_SIZE: usize = 256;
pub const DBCN_MAX_WRITE_BYTES: usize = 4096;

pub const DEFAULT_ROOT_RAM_BYTES: usize =
    if (@hasDecl(config, "root_ram_max_mb"))
        @as(usize, config.root_ram_max_mb) * 1024 * 1024
    else
        512 * 1024 * 1024;
pub const DEFAULT_CHILD_RAM_BYTES: usize =
    if (@hasDecl(config, "child_ram_default_mb"))
        @as(usize, config.child_ram_default_mb) * 1024 * 1024
    else
        256 * 1024 * 1024;
pub const MAX_FOREIGN_MAP_SIZE_BYTES: usize = 512 * 1024 * 1024;
pub const DIOSIX_CHILD_MEM_BASE: usize = 0x200000000;
pub const DIOSIX_CHILD_MEM_MAX_SIZE: usize = 256 * 1024 * 1024;
pub const MAX_MANIFEST_SIZE_BYTES: usize = 1024 * 1024;
pub const MAX_USER_CID_DISCRIMINATOR: usize =
    guest.CID_FIRST_CHILD + guest.MAX_CHILD_HANDLES;
pub const DEFAULT_VERSION_MAJOR: u16 = interface.DEFAULT_VERSION_MAJOR;
pub const DEFAULT_VERSION_MINOR: u16 = interface.DEFAULT_VERSION_MINOR;

comptime {
    std.debug.assert(DEFAULT_ROOT_RAM_BYTES > 0);
    std.debug.assert(DEFAULT_CHILD_RAM_BYTES > 0);
}

// SBI Error Codes.
pub const SBI_SUCCESS = interface.SUCCESS;
pub const SBI_ERR_FAILED = interface.ERR_FAILED;
pub const SBI_ERR_NOT_SUPPORTED = interface.ERR_NOT_SUPPORTED;
pub const SBI_ERR_INVALID_PARAM = interface.ERR_INVALID_PARAM;
pub const SBI_ERR_DENIED = interface.ERR_DENIED;
pub const SBI_ERR_INVALID_ADDRESS = interface.ERR_INVALID_ADDRESS;
pub const SBI_ERR_ALREADY_AVAILABLE = interface.ERR_ALREADY_AVAILABLE;

pub const A0_REG = @backingInt(arch.Register.a0);
pub const A1_REG = @backingInt(arch.Register.a1);
pub const A2_REG = @backingInt(arch.Register.a2);
pub const A6_REG = @backingInt(arch.Register.a6);
pub const A7_REG = @backingInt(arch.Register.a7);

pub fn handle(
    vc: *vcore.VirtualCore,
    sub_idx: usize,
    context: *riscv.ThreadContext,
) void {
    const E = interface.EXT;
    const extension = context[A7_REG];
    const function = context[A6_REG];
    const a0 = context[A0_REG];
    const a1 = context[A1_REG];
    const a2 = context[A2_REG];
    switch (extension) {
        E.BASE => handleBase(vc, context, function),
        E.TIME, E.LEGACY_SET_TIMER => {
            const stime = if (vc.exec_path == .emulated)
                (a0 & RV32_WORD_MASK) |
                    ((@as(u64, a1) & RV32_WORD_MASK) << RV32_HIGH_SHIFT)
            else
                a0;
            handleTimer(vc, sub_idx, context, stime);
        },
        E.SRST => handleSystemReset(vc, context, function, a0, a1),
        E.HSM => standard.handleHSM(vc, sub_idx, context, function, a0, a1, a2),
        E.DBCN => {
            standard.handleDebugConsole(vc, context, function, a0, a1, a2);
        },
        E.IPI => standard.handleIPI(vc, context, a0, a1),
        E.RFENCE => standard.handleRFENCE(vc, context, function, a0, a1),
        E.LEGACY_CONSOLE_PUTCHAR => {
            if (vc.guest.is_root) debug.putchar(@truncate(a0));
        },
        E.LEGACY_CONSOLE_GETCHAR => {
            const ch: isize = if (vc.guest.is_root) debug.getchar() else -1;
            const raw: usize = @bitCast(ch);
            context[A0_REG] = raw;
            if (vc.exec_path == .native) {
                vc.getNativeContext()[A0_REG] = raw;
            } else if (vc.exec_path == .emulated) {
                if (vc.exec_path.emulated.vcpu) |v| {
                    v.setGpr(A0_REG, @truncate(raw));
                }
            }
        },
        E.LEGACY_CLEAR_IPI => {
            if (vc.exec_path == .emulated) {
                if (vc.exec_path.emulated.vcpu) |v| v.clearMipBit(MIP_SSIP_BIT);
                const sub_ipi =
                    &vc.exec_path.emulated.sub_vcores[sub_idx].pending_ipi;
                _ = @atomicRmw(bool, sub_ipi, .Xchg, false, .acq_rel);
            } else {
                vc.getNativeMachine().hvip &= ~@as(usize, riscv.HVIP.VSSIP);
                riscv.writeHvip(vc.getNativeMachine().hvip);
                const hid = riscv.getCPUContext().hardware_hart_id;
                if (riscv.CLINT.msip(hid)) |ptr| ptr.* = 0;
                _ = @atomicRmw(bool, &vc.pending_ipi, .Xchg, false, .acq_rel);
            }
            setResult(vc, context, SBI_SUCCESS, 0);
        },
        E.LEGACY_SEND_IPI => standard.handleLegacySendIpi(vc, context),
        E.LEGACY_REMOTE_FENCE_I,
        E.LEGACY_REMOTE_SFENCE_VMA,
        E.LEGACY_REMOTE_SFENCE_VMA_ASID,
        => {
            if (vc.exec_path == .emulated) {
                if (vc.exec_path.emulated.engine) |eng| eng.tlb.flush();
            } else {
                if (riscv.hasHExtension()) {
                    riscv.hfenceGvma();
                } else {
                    riscv.sfenceVma();
                }
                riscv.getCPUContext().gstage_dirty = false;
                broadcastPhysicalIPI();
            }
            setResult(vc, context, SBI_SUCCESS, 0);
        },
        E.LEGACY_SHUTDOWN => {
            debug.printf(
                "SBI: Guest {} requested legacy shutdown\n",
                .{vc.guest_id},
            );
            terminateOrRestart(vc.getGuest(), 0);
        },
        E.DIOSIX => {
            diosix_sbi.handleDiosix(vc, context, function, a0, a1, a2);
        },
        else => {
            debug.printf(
                "SBI: Unknown ext 0x{x} func {} from {}\n",
                .{ extension, function, vc.id },
            );
            setResult(vc, context, SBI_ERR_NOT_SUPPORTED, 0);
        },
    }

    if (vc.exec_path == .native) {
        const self_terminated = vc.getGuest().state != .valid;
        const did_yield = self_terminated or
            (extension == E.DIOSIX and function == interface.DIOSIX.YIELD) or
            (extension == E.HSM and
                (function == interface.HSM.HART_STOP or
                    function == interface.HSM.HART_SUSPEND));
        if (!did_yield) {
            vc.getNativeMachine().mepc += ECALL_INSTRUCTION_SIZE_BYTES;
            riscv.writeMepc(vc.getNativeMachine().mepc);
        }
    }
}

fn handleBase(
    vc: *vcore.VirtualCore,
    context: *riscv.ThreadContext,
    function: usize,
) void {
    const B = interface.BASE;
    const E = interface.EXT;
    switch (function) {
        B.GET_SPEC_VERSION => {
            setResult(vc, context, SBI_SUCCESS, interface.SPEC_VERSION);
        },
        B.GET_IMPL_ID => setResult(vc, context, SBI_SUCCESS, interface.IMPL_ID),
        B.GET_IMPL_VERSION => {
            setResult(vc, context, SBI_SUCCESS, interface.IMPL_VERSION);
        },
        B.PROBE_EXTENSION => {
            const supported: usize = switch (context[A0_REG]) {
                E.BASE,
                E.TIME,
                E.SRST,
                E.HSM,
                E.DBCN,
                E.IPI,
                E.RFENCE,
                E.DIOSIX,
                E.LEGACY_CONSOLE_PUTCHAR,
                E.LEGACY_CLEAR_IPI,
                E.LEGACY_SEND_IPI,
                E.LEGACY_REMOTE_FENCE_I,
                E.LEGACY_REMOTE_SFENCE_VMA,
                E.LEGACY_REMOTE_SFENCE_VMA_ASID,
                E.LEGACY_SHUTDOWN,
                => 1,
                else => 0,
            };
            setResult(vc, context, SBI_SUCCESS, supported);
        },
        B.GET_MVENDORID => {
            setResult(vc, context, SBI_SUCCESS, riscv.readMvendorid());
        },
        B.GET_MARCHID => {
            setResult(vc, context, SBI_SUCCESS, riscv.readMarchid());
        },
        B.GET_MIMPID => setResult(vc, context, SBI_SUCCESS, riscv.readMimpid()),
        else => setResult(vc, context, SBI_ERR_NOT_SUPPORTED, 0),
    }
}

fn handleTimer(
    vc: *vcore.VirtualCore,
    sub_idx: usize,
    context: *riscv.ThreadContext,
    stime: u64,
) void {
    if (vc.exec_path == .emulated) {
        vc.timer_target = stime;
        vc.timer_scheduled = (stime != 0 and stime != riscv.TIMER_INFINITY);
        if (sub_idx < vcore.max_sub_vcores) {
            const sub = &vc.exec_path.emulated.sub_vcores[sub_idx];
            sub.timer_target = stime;
            sub.timer_scheduled = vc.timer_scheduled;
        }
        if (vc.exec_path.emulated.vcpu) |v| {
            v.vstimecmp = stime;
            v.clearMipBit(MIP_STIP_BIT);
        }
        if (vc.timer_scheduled) riscv.setTimer(stime +% vcore.time_offset);
    } else {
        vc.getNativeGuestState().vstimecmp = stime;
        if (!config.legacy_cpu and riscv.riscv_supports_sstc) {
            riscv.writeVstimecmp(stime);
            vc.getNativeMachine().hvip &= ~@as(usize, riscv.HVIP.VSTIP);
            riscv.writeHvip(vc.getNativeMachine().hvip);
        }
        if (stime != 0 and stime != riscv.TIMER_INFINITY) riscv.setTimer(stime);
    }
    setResult(vc, context, SBI_SUCCESS, 0);
}

fn handleSystemReset(
    vc: *vcore.VirtualCore,
    _: *riscv.ThreadContext,
    _: usize,
    reset_type: usize,
    _: usize,
) void {
    const g = vc.getGuest();
    debug.printf(
        "SBI: System Reset (type {}) by guest {}\n",
        .{ reset_type, g.id },
    );
    const exit_code: usize =
        if (reset_type == interface.SRST.TYPE_SHUTDOWN) 0 else 1;
    terminateOrRestart(g, exit_code);
}

pub fn setResult(
    vc: *vcore.VirtualCore,
    context: *riscv.ThreadContext,
    err: isize,
    val: usize,
) void {
    const raw_err: usize = @bitCast(err);
    context[@backingInt(arch.Register.a0)] = raw_err;
    context[@backingInt(arch.Register.a1)] = val;
    if (vc.exec_path == .native) {
        vc.getNativeContext()[@backingInt(arch.Register.a0)] = raw_err;
        vc.getNativeContext()[@backingInt(arch.Register.a1)] = val;
    } else if (vc.exec_path == .emulated) {
        if (vc.exec_path.emulated.vcpu) |v| {
            v.setGpr(@backingInt(arch.Register.a0), @truncate(raw_err));
            v.setGpr(@backingInt(arch.Register.a1), @truncate(val));
        }
    }
}

pub fn deliverToQueue(
    target: *guest.Guest,
    q: *guest.PacketQueue,
    data: []const u8,
) void {
    if (q.push(data)) {
        var it = target.vcores.start;
        while (it) |node| : (it = node.next) {
            if (node.contents.tryWake()) {
                scheduler.queue(node.contents);
                broadcastPhysicalIPI();
            }
        }
    }
}

pub fn terminateOrRestart(g: *guest.Guest, exit_code: usize) void {
    const builtin = @import("builtin");
    if (g.is_root and exit_code != 0) {
        if (g.findStandbyRoot()) |standby| {
            if (guest.Guest.promoteStandbyRoot(g, standby)) |_| {
                _ = charter.incrementFailoverEpoch();
                debug.printf(
                    "Root VM crashed (exit code {}). Promoted Standby Root.\n",
                    .{exit_code},
                );
                g.terminateWithCode(exit_code);
                if (!builtin.is_test) scheduler.schedule();
                return;
            } else |_| {}
        }
    }
    if (g.state != .restarting) {
        const was_root = g.is_root;
        g.terminateWithCode(exit_code);
        if (was_root) {
            if (exit_code == 0) {
                debug.printf("Root VM exited 0. Powering off host.\n", .{});
                riscv.shutdown();
            } else {
                debug.printf(
                    "Root VM exited {}. Rebooting host.\n",
                    .{exit_code},
                );
                riscv.reboot();
            }
        }
        if (!builtin.is_test) scheduler.schedule();
    }
}

pub const ParsedVersion = struct { major: u16, minor: u16, patch: u16 };

pub fn parseVersionString(raw: []const u8) ParsedVersion {
    var core = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.indexOfAny(u8, core, "-+")) |sep| core = core[0..sep];
    const fallback = ParsedVersion{
        .major = DEFAULT_VERSION_MAJOR,
        .minor = DEFAULT_VERSION_MINOR,
        .patch = 0,
    };
    var it = std.mem.splitScalar(u8, core, '.');
    const major_str = it.next() orelse return fallback;
    const minor_str = it.next() orelse return fallback;
    const patch_str = it.next();
    return .{
        .major = std.fmt.parseInt(u16, major_str, 10) catch fallback.major,
        .minor = std.fmt.parseInt(u16, minor_str, 10) catch fallback.minor,
        .patch = if (patch_str) |ps|
            (std.fmt.parseInt(u16, ps, 10) catch 0)
        else
            0,
    };
}

pub fn broadcastPhysicalIPI() void {
    pcore.broadcastIpi();
}

test "parseVersionString and SBI Base extension dispatch" {
    std.testing.refAllDecls(@This());
    _ = charter;
    _ = diosix_sbi;
    _ = standard;
    _ = @import("sbi/ipc.zig");
    _ = @import("sbi/info.zig");
    const testing = std.testing;
    try testing.expectEqual(
        ParsedVersion{ .major = 26, .minor = 1, .patch = 0 },
        parseVersionString("26.1\n"),
    );
    try testing.expectEqual(
        ParsedVersion{ .major = 26, .minor = 2, .patch = 1 },
        parseVersionString("26.2.1"),
    );
    try testing.expectEqual(
        ParsedVersion{ .major = 26, .minor = 2, .patch = 3 },
        parseVersionString("26.2.3-dev+abcdef\n"),
    );

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
    var ctx: riscv.ThreadContext = @splat(0);

    ctx[A7_REG] = interface.EXT.BASE;
    ctx[A6_REG] = interface.BASE.GET_SPEC_VERSION;
    handle(&vc, 0, &ctx);
    try testing.expectEqual(@as(usize, 0), ctx[A0_REG]);
    try testing.expectEqual(@as(usize, interface.SPEC_VERSION), ctx[A1_REG]);

    ctx[A6_REG] = interface.BASE.PROBE_EXTENSION;
    ctx[A0_REG] = interface.EXT.DIOSIX;
    handle(&vc, 0, &ctx);
    try testing.expectEqual(@as(usize, 0), ctx[A0_REG]);
    try testing.expectEqual(@as(usize, 1), ctx[A1_REG]);

    ctx[A7_REG] = 0x99999999;
    ctx[A6_REG] = 0;
    handle(&vc, 0, &ctx);
    const not_sup: usize = @bitCast(SBI_ERR_NOT_SUPPORTED);
    try testing.expectEqual(not_sup, ctx[A0_REG]);
}
