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
pub const MIP_SSIP_BIT: u6 = 1;
pub const MIP_STIP_BIT: u6 = 5;
pub const DBCN_CHUNK_BUFFER_SIZE: usize = 256;
pub const DBCN_MAX_WRITE_BYTES: usize = 4096;

pub const DEFAULT_ROOT_RAM_BYTES: usize = 512 * 1024 * 1024;
pub const DEFAULT_CHILD_RAM_BYTES: usize = 256 * 1024 * 1024;
pub const MAX_FOREIGN_MAP_SIZE_BYTES: usize = 512 * 1024 * 1024;
pub const DIOSIX_CHILD_MEM_BASE: usize = 0x200000000;
pub const DIOSIX_CHILD_MEM_MAX_SIZE: usize = 256 * 1024 * 1024;
pub const MAX_MANIFEST_SIZE_BYTES: usize = 1024 * 1024;
pub const MAX_USER_CID_DISCRIMINATOR: usize = physmem.PageSize;
pub const DEFAULT_VERSION_MAJOR: u16 = 26;
pub const DEFAULT_VERSION_MINOR: u16 = 1;

// SBI Error Codes.
pub const SBI_SUCCESS = interface.SUCCESS;
pub const SBI_ERR_FAILED = interface.ERR_FAILED;
pub const SBI_ERR_NOT_SUPPORTED = interface.ERR_NOT_SUPPORTED;
pub const SBI_ERR_INVALID_PARAM = interface.ERR_INVALID_PARAM;
pub const SBI_ERR_DENIED = interface.ERR_DENIED;
pub const SBI_ERR_INVALID_ADDRESS = interface.ERR_INVALID_ADDRESS;
pub const SBI_ERR_ALREADY_AVAILABLE = interface.ERR_ALREADY_AVAILABLE;

pub fn handle(
    vc: *vcore.VirtualCore,
    sub_idx: usize,
    context: *riscv.ThreadContext,
) void {
    const extension = context[@backingInt(arch.Register.a7)];
    const function = context[@backingInt(arch.Register.a6)];
    const a0 = context[@backingInt(arch.Register.a0)];
    const a1 = context[@backingInt(arch.Register.a1)];
    const a2 = context[@backingInt(arch.Register.a2)];
    switch (extension) {
        interface.EXT.BASE => handleBase(vc, context, function),
        interface.EXT.TIME, interface.EXT.LEGACY_SET_TIMER => {
            const stime = if (vc.exec_path == .emulated)
                (a0 & RV32_WORD_MASK) |
                    ((@as(u64, a1) & RV32_WORD_MASK) << RV32_HIGH_SHIFT)
            else
                a0;
            handleTimer(vc, sub_idx, context, stime);
        },
        interface.EXT.SRST => handleSystemReset(vc, context, function, a0, a1),
        interface.EXT.HSM => {
            standard.handleHSM(vc, sub_idx, context, function, a0, a1, a2);
        },
        interface.EXT.DBCN => {
            standard.handleDebugConsole(vc, context, function, a0, a1, a2);
        },
        interface.EXT.IPI => standard.handleIPI(vc, context, a0, a1),
        interface.EXT.RFENCE => {
            standard.handleRFENCE(vc, context, function, a0, a1);
        },
        interface.EXT.LEGACY_CONSOLE_PUTCHAR => {
            if (vc.guest.is_root) debug.putchar(@truncate(a0));
        },
        interface.EXT.LEGACY_CONSOLE_GETCHAR => {
            const char_val: isize = if (vc.guest.is_root)
                @as(isize, debug.getchar())
            else
                -1;
            const raw: usize = @bitCast(char_val);
            context[@backingInt(arch.Register.a0)] = raw;
            if (vc.exec_path == .native) {
                vc.getNativeContext()[@backingInt(arch.Register.a0)] = raw;
            } else if (vc.exec_path == .emulated) {
                if (vc.exec_path.emulated.vcpu) |v| {
                    v.setGpr(@backingInt(arch.Register.a0), @truncate(raw));
                }
            }
        },
        interface.EXT.LEGACY_CLEAR_IPI => {
            if (vc.exec_path == .emulated) {
                if (vc.exec_path.emulated.vcpu) |v| v.clearMipBit(MIP_SSIP_BIT);
                _ = @atomicRmw(
                    bool,
                    &vc.exec_path.emulated.sub_vcores[sub_idx].pending_ipi,
                    .Xchg,
                    false,
                    .acq_rel,
                );
            } else {
                vc.getNativeMachine().hvip &= ~@as(usize, riscv.HVIP.VSSIP);
                riscv.writeHvip(vc.getNativeMachine().hvip);
                const hid = riscv.getCPUContext().hardware_hart_id;
                if (riscv.CLINT.msip(hid)) |ptr| ptr.* = 0;
                _ = @atomicRmw(bool, &vc.pending_ipi, .Xchg, false, .acq_rel);
            }
            setResult(vc, context, SBI_SUCCESS, 0);
        },
        interface.EXT.LEGACY_SEND_IPI => {
            standard.handleLegacySendIpi(vc, context);
        },
        interface.EXT.LEGACY_REMOTE_FENCE_I,
        interface.EXT.LEGACY_REMOTE_SFENCE_VMA,
        interface.EXT.LEGACY_REMOTE_SFENCE_VMA_ASID,
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
        interface.EXT.LEGACY_SHUTDOWN => {
            debug.printf(
                "SBI: Guest {} requested legacy shutdown\n",
                .{vc.guest_id},
            );
            terminateOrRestart(vc.getGuest(), 0);
        },
        interface.EXT.DIOSIX => {
            diosix_sbi.handleDiosix(vc, context, function, a0, a1, a2);
        },
        else => {
            debug.printf(
                "SBI: Unknown extension 0x{x} func {} from guest {}\n",
                .{ extension, function, vc.id },
            );
            setResult(vc, context, SBI_ERR_NOT_SUPPORTED, 0);
        },
    }

    if (vc.exec_path == .native) {
        const did_yield = (extension == interface.EXT.DIOSIX and
            function == interface.DIOSIX.YIELD) or
            (extension == interface.EXT.HSM and
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
    switch (function) {
        interface.BASE.GET_SPEC_VERSION => {
            setResult(vc, context, SBI_SUCCESS, interface.SPEC_VERSION);
        },
        interface.BASE.GET_IMPL_ID => {
            setResult(vc, context, SBI_SUCCESS, interface.IMPL_ID);
        },
        interface.BASE.GET_IMPL_VERSION => {
            setResult(vc, context, SBI_SUCCESS, interface.IMPL_VERSION);
        },
        interface.BASE.PROBE_EXTENSION => {
            const ext = context[@backingInt(arch.Register.a0)];
            const supported: usize = switch (ext) {
                interface.EXT.BASE,
                interface.EXT.TIME,
                interface.EXT.SRST,
                interface.EXT.HSM,
                interface.EXT.DBCN,
                interface.EXT.IPI,
                interface.EXT.RFENCE,
                interface.EXT.DIOSIX,
                interface.EXT.LEGACY_CONSOLE_PUTCHAR,
                interface.EXT.LEGACY_CLEAR_IPI,
                interface.EXT.LEGACY_SEND_IPI,
                interface.EXT.LEGACY_REMOTE_FENCE_I,
                interface.EXT.LEGACY_REMOTE_SFENCE_VMA,
                interface.EXT.LEGACY_REMOTE_SFENCE_VMA_ASID,
                interface.EXT.LEGACY_SHUTDOWN,
                => 1,
                else => 0,
            };
            setResult(vc, context, SBI_SUCCESS, supported);
        },
        interface.BASE.GET_MVENDORID => {
            setResult(vc, context, SBI_SUCCESS, riscv.readMvendorid());
        },
        interface.BASE.GET_MARCHID => {
            setResult(vc, context, SBI_SUCCESS, riscv.readMarchid());
        },
        interface.BASE.GET_MIMPID => {
            setResult(vc, context, SBI_SUCCESS, riscv.readMimpid());
        },
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
        vc.timer_scheduled = (stime != 0 and stime != std.math.maxInt(u64));
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
        if (stime != 0 and stime != std.math.maxInt(u64)) {
            riscv.setTimer(stime);
        }
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
        "SBI: System Reset (type {}) requested by guest {}\n",
        .{ reset_type, g.id },
    );
    g.terminate();
    if (g.is_root) {
        if (reset_type == interface.SRST.TYPE_SHUTDOWN) {
            debug.printf("Root VM requested shutdown. Powering off.\n", .{});
            riscv.shutdown();
        } else {
            debug.printf("Root VM requested reboot. Restarting host.\n", .{});
            riscv.reboot();
        }
    }
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
    if (g.is_root and exit_code != 0) {
        if (g.findStandbyRoot()) |standby| {
            if (guest.Guest.promoteStandbyRoot(g, standby)) |_| {
                _ = charter.incrementFailoverEpoch();
                debug.printf(
                    "Root VM crashed (exit code {}). Promoted Standby Root.\n",
                    .{exit_code},
                );
                g.terminateWithCode(exit_code);
                return;
            } else |_| {}
        }
    }
    const was_root = g.is_root;
    g.terminateWithCode(exit_code);
    if (was_root) {
        if (exit_code == 0) {
            debug.printf("Root VM exited 0. Powering off host.\n", .{});
            riscv.shutdown();
        } else {
            debug.printf("Root VM exited {}. Rebooting host.\n", .{exit_code});
            riscv.reboot();
        }
    }
}

pub const ParsedVersion = struct {
    major: u16,
    minor: u16,
    patch: u16,
};

pub fn parseVersionString(raw: []const u8) ParsedVersion {
    var core = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.indexOfAny(u8, core, "-+")) |sep| core = core[0..sep];

    var it = std.mem.splitScalar(u8, core, '.');
    const major_str = it.next() orelse return .{
        .major = DEFAULT_VERSION_MAJOR,
        .minor = DEFAULT_VERSION_MINOR,
        .patch = 0,
    };
    const minor_str = it.next() orelse return .{
        .major = DEFAULT_VERSION_MAJOR,
        .minor = DEFAULT_VERSION_MINOR,
        .patch = 0,
    };
    const patch_str = it.next();

    return .{
        .major = std.fmt.parseInt(u16, major_str, 10) catch
            DEFAULT_VERSION_MAJOR,
        .minor = std.fmt.parseInt(u16, minor_str, 10) catch
            DEFAULT_VERSION_MINOR,
        .patch = if (patch_str) |ps|
            (std.fmt.parseInt(u16, ps, 10) catch 0)
        else
            0,
    };
}

pub fn broadcastPhysicalIPI() void {
    pcore.broadcastIpi();
}

test "parseVersionString CalVer major.minor.patch parsing" {
    _ = charter;
    _ = diosix_sbi;
    _ = standard;
    const testing = std.testing;
    const v1 = parseVersionString("26.1\n");
    try testing.expectEqual(@as(u16, 26), v1.major);
    try testing.expectEqual(@as(u16, 1), v1.minor);
    try testing.expectEqual(@as(u16, 0), v1.patch);

    const v2 = parseVersionString("26.2.1");
    try testing.expectEqual(@as(u16, 26), v2.major);
    try testing.expectEqual(@as(u16, 2), v2.minor);
    try testing.expectEqual(@as(u16, 1), v2.patch);

    const v3 = parseVersionString("26.2.3-dev+abcdef\n");
    try testing.expectEqual(@as(u16, 26), v3.major);
    try testing.expectEqual(@as(u16, 2), v3.minor);
    try testing.expectEqual(@as(u16, 3), v3.patch);
}

test "SBI Base extension dispatch" {
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

    ctx[@backingInt(arch.Register.a7)] = interface.EXT.BASE;
    ctx[@backingInt(arch.Register.a6)] = interface.BASE.GET_SPEC_VERSION;
    handle(&vc, 0, &ctx);
    try testing.expectEqual(@as(usize, 0), ctx[@backingInt(arch.Register.a0)]);
    try testing.expectEqual(
        @as(usize, interface.SPEC_VERSION),
        ctx[@backingInt(arch.Register.a1)],
    );

    ctx[@backingInt(arch.Register.a6)] = interface.BASE.PROBE_EXTENSION;
    ctx[@backingInt(arch.Register.a0)] = interface.EXT.DIOSIX;
    handle(&vc, 0, &ctx);
    try testing.expectEqual(@as(usize, 0), ctx[@backingInt(arch.Register.a0)]);
    try testing.expectEqual(@as(usize, 1), ctx[@backingInt(arch.Register.a1)]);

    ctx[@backingInt(arch.Register.a7)] = 0x99999999;
    ctx[@backingInt(arch.Register.a6)] = 0;
    handle(&vc, 0, &ctx);
    try testing.expectEqual(
        @as(usize, @bitCast(SBI_ERR_NOT_SUPPORTED)),
        ctx[@backingInt(arch.Register.a0)],
    );
}
