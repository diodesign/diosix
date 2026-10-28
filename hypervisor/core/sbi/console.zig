// Diosix SBI parent-to-child serial console I/O handlers.
//
// Allows a parent VM (or Root VM) to read a child guest's SBI DBCN / legacy
// console output stream (console_tx) and inject console input (console_rx)
// while enforcing confidential and sealed-Steward isolation boundaries.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const riscv = @import("../../hardware/native/cpu/riscv64/mod.zig");
const sv39x4 = @import("../../hardware/native/cpu/riscv64/sv39x4.zig");
const vcore = @import("../vcore.zig");
const guest = @import("../guest.zig");
const physmem = @import("../physmem.zig");
const scheduler = @import("../scheduler.zig");
const pcore = @import("../pcore.zig");
const sbi_core = @import("../sbi.zig");
const charter = @import("charter.zig");
const standard = @import("standard.zig");
const interface = @import("interface").sbi;

fn canAccessGuestConsole(
    caller: *const guest.Guest,
    target: *const guest.Guest,
) bool {
    if (target != caller and target.parent != caller and !caller.is_root) {
        return false;
    }
    if (target != caller) {
        if (target.is_confidential) return false;
        if (target.is_steward and charter.isCharterSealed()) return false;
    }
    return true;
}

fn wakeTargetVcores(target: *guest.Guest) void {
    var it = target.vcores.start;
    while (it) |node| : (it = node.next) {
        if (node.contents.tryWake()) {
            scheduler.queue(node.contents);
            pcore.wakeIdleCores();
        }
    }
}

pub fn handleConsoleRead(
    vc: *vcore.VirtualCore,
    context: *riscv.ThreadContext,
    g: *guest.Guest,
    a0: usize,
) void {
    var cargs = g.space.readGuestStruct(interface.ConsoleArgs, a0) catch {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
        return;
    };
    const target = g.getGuestByCid(@intCast(cargs.target_cid)) orelse {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_INVALID_PARAM, 0);
        return;
    };
    if (!canAccessGuestConsole(g, target)) {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_DENIED, 0);
        return;
    }

    const req_len: usize = @intCast(cargs.max_len);
    if (req_len > interface.MAX_CONSOLE_IO_BYTES) {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_INVALID_PARAM, 0);
        return;
    }
    if (req_len == 0) {
        cargs.actual_len = target.console_tx.getCount();
        g.space.writeGuestStruct(interface.ConsoleArgs, a0, cargs) catch {
            sbi_core.setResult(
                vc,
                context,
                sbi_core.SBI_ERR_INVALID_ADDRESS,
                0,
            );
            return;
        };
        sbi_core.setResult(vc, context, sbi_core.SBI_SUCCESS, 0);
        return;
    }

    const data_ptr: usize = @intCast(cargs.data_ptr);
    if (data_ptr == 0) {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_INVALID_PARAM, 0);
        return;
    }
    _ = std.math.add(usize, data_ptr, req_len) catch {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
        return;
    };

    var total_read: usize = 0;
    var chunk_buf: [sbi_core.DBCN_CHUNK_BUFFER_SIZE]u8 = undefined;
    while (total_read < req_len) {
        const want: usize = @min(req_len - total_read, chunk_buf.len);
        const got = target.console_tx.popSlice(chunk_buf[0..want]);
        if (got == 0) break;
        g.space.copyToGuest(data_ptr + total_read, chunk_buf[0..got]) catch {
            sbi_core.setResult(
                vc,
                context,
                sbi_core.SBI_ERR_INVALID_ADDRESS,
                total_read,
            );
            return;
        };
        total_read += got;
        if (got < want) break;
    }

    cargs.actual_len = total_read;
    g.space.writeGuestStruct(interface.ConsoleArgs, a0, cargs) catch {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
        return;
    };
    sbi_core.setResult(vc, context, sbi_core.SBI_SUCCESS, total_read);
}

pub fn handleConsoleWrite(
    vc: *vcore.VirtualCore,
    context: *riscv.ThreadContext,
    g: *guest.Guest,
    a0: usize,
) void {
    var cargs = g.space.readGuestStruct(interface.ConsoleArgs, a0) catch {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
        return;
    };
    const target = g.getGuestByCid(@intCast(cargs.target_cid)) orelse {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_INVALID_PARAM, 0);
        return;
    };
    if (!canAccessGuestConsole(g, target)) {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_DENIED, 0);
        return;
    }

    const req_len: usize = @intCast(cargs.max_len);
    const data_ptr: usize = @intCast(cargs.data_ptr);
    if (req_len == 0 or req_len > interface.MAX_CONSOLE_IO_BYTES or
        data_ptr == 0)
    {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_INVALID_PARAM, 0);
        return;
    }
    _ = std.math.add(usize, data_ptr, req_len) catch {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
        return;
    };

    var written: usize = 0;
    var chunk_buf: [sbi_core.DBCN_CHUNK_BUFFER_SIZE]u8 = undefined;
    while (written < req_len) {
        const chunk: usize = @min(req_len - written, chunk_buf.len);
        g.space.copyFromGuest(chunk_buf[0..chunk], data_ptr + written) catch {
            sbi_core.setResult(
                vc,
                context,
                sbi_core.SBI_ERR_INVALID_ADDRESS,
                written,
            );
            return;
        };
        _ = target.console_rx.pushSlice(chunk_buf[0..chunk]);
        written += chunk;
    }

    wakeTargetVcores(target);
    cargs.actual_len = written;
    g.space.writeGuestStruct(interface.ConsoleArgs, a0, cargs) catch {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
        return;
    };
    sbi_core.setResult(vc, context, sbi_core.SBI_SUCCESS, written);
}

test "SBI parent-child console read, write, and confidential isolation" {
    std.testing.refAllDecls(@This());
    const testing = std.testing;
    const alloc = testing.allocator;
    const arch = @import("interface").riscv;
    scheduler.init();
    scheduler.initCpu();
    var phys_test = try physmem.initForTest(alloc, 128);
    defer phys_test.deinit();

    const parent = try guest.createGuest(
        alloc,
        true,
        true,
        null,
        0,
        0,
        0,
        .riscv64,
    );
    defer parent.deinit();
    const p_page = try physmem.allocPage();
    try parent.space.map(
        0x80000000,
        p_page,
        physmem.PageSize,
        sv39x4.PTEFlags.leaf_rw_user,
    );
    physmem.decrementPageRef(p_page);

    const child = try parent.createChild(false, .riscv64, 1);
    defer child.deinit();
    const c_page = try physmem.allocPage();
    try child.space.map(
        0x80000000,
        c_page,
        physmem.PageSize,
        sv39x4.PTEFlags.leaf_rw_user,
    );
    physmem.decrementPageRef(c_page);

    var p_vc = vcore.VirtualCore.init(0, parent, 0x80000000, 0, .normal);
    var c_vc = vcore.VirtualCore.init(0, child, 0x80000000, 0, .normal);
    var ctx: riscv.ThreadContext = @splat(0);
    const a0_reg = @backingInt(arch.Register.a0);
    const a1_reg = @backingInt(arch.Register.a1);

    // 1. Child writes "boot ok\n" via DBCN.CONSOLE_WRITE; parent reads it.
    try child.space.copyToGuest(0x80000100, "boot ok\n");
    standard.handleDebugConsole(
        &c_vc,
        &ctx,
        interface.DBCN.CONSOLE_WRITE,
        8,
        0x80000100,
        0,
    );
    try testing.expectEqual(@as(usize, 0), ctx[a0_reg]);
    try testing.expectEqual(@as(usize, 8), ctx[a1_reg]);

    const rargs = interface.ConsoleArgs{
        .target_cid = child.local_cid,
        .data_ptr = 0x80000200,
        .max_len = 64,
    };
    try parent.space.writeGuestStruct(interface.ConsoleArgs, 0x80000000, rargs);
    handleConsoleRead(&p_vc, &ctx, parent, 0x80000000);
    try testing.expectEqual(@as(usize, 0), ctx[a0_reg]);
    try testing.expectEqual(@as(usize, 8), ctx[a1_reg]);
    var out_buf: [8]u8 = undefined;
    try parent.space.copyFromGuest(&out_buf, 0x80000200);
    try testing.expectEqualStrings("boot ok\n", &out_buf);

    // 2. Parent writes "ls\n" via DIOSIX.CONSOLE_WRITE; child reads via DBCN.
    try parent.space.copyToGuest(0x80000300, "ls\n");
    const wargs = interface.ConsoleArgs{
        .target_cid = child.local_cid,
        .data_ptr = 0x80000300,
        .max_len = 3,
    };
    try parent.space.writeGuestStruct(interface.ConsoleArgs, 0x80000000, wargs);
    handleConsoleWrite(&p_vc, &ctx, parent, 0x80000000);
    try testing.expectEqual(@as(usize, 0), ctx[a0_reg]);
    try testing.expectEqual(@as(usize, 3), ctx[a1_reg]);

    standard.handleDebugConsole(
        &c_vc,
        &ctx,
        interface.DBCN.CONSOLE_READ,
        16,
        0x80000400,
        0,
    );
    try testing.expectEqual(@as(usize, 0), ctx[a0_reg]);
    try testing.expectEqual(@as(usize, 3), ctx[a1_reg]);
    var in_buf: [3]u8 = undefined;
    try child.space.copyFromGuest(&in_buf, 0x80000400);
    try testing.expectEqualStrings("ls\n", &in_buf);

    // 3. Confidential child blocks parent console snooping/injection.
    child.is_confidential = true;
    handleConsoleRead(&p_vc, &ctx, parent, 0x80000000);
    const denied: usize = @bitCast(sbi_core.SBI_ERR_DENIED);
    try testing.expectEqual(denied, ctx[a0_reg]);
}
