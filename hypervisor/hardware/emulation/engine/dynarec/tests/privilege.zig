// Unit Tests for Dynarec Block Cache, Direct RAM Regions & Privilege Checks.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const decoder_rv32 = @import("../../decoders/rv32.zig");
const emitter_rv64 = @import("../../emitters/rv64.zig");
const cache_mod = @import("../cache.zig");
const softtlb_mod = @import("../../../softtlb.zig");
const vcpu_mod = @import("../../../vcpu.zig");
const bus_mod = @import("../../../devices/bus.zig");
const vuart_mod = @import("../../../devices/vuart.zig");
const vtimer_mod = @import("../../../devices/vtimer.zig");
const vpic_mod = @import("../../../devices/vpic.zig");
const engine_mod = @import("../engine.zig");
const riscv = @import("interface").riscv;

test "Dynarec global vs ASID-specific block retention across context switches" {
    const cache_inst = try std.testing.allocator.create(cache_mod.Cache);
    defer std.testing.allocator.destroy(cache_inst);
    var raw_pool: [8192]u8 align(4096) = undefined;
    cache_inst.initOnPtr(&raw_pool);

    // 1. Allocate a global kernel block (e.g. supervisor __schedule).
    const tb_kernel = try cache_inst.allocateBlock(
        0xc004_f61e,
        0x8000_1111,
        true,
        256,
    );
    cache_inst.commitBlock(tb_kernel, 64);

    // 2. Allocate a process-specific user block (satp=0x80001111).
    const tb_user_proc1 = try cache_inst.allocateBlock(
        0x0001_0000,
        0x8000_1111,
        false,
        256,
    );
    cache_inst.commitBlock(tb_user_proc1, 64);

    // 3. Lookup with satp=0x80001111 -> both should hit.
    const hit_kernel_1 = cache_inst.lookup(0xc004_f61e, 0x8000_1111);
    try std.testing.expect(hit_kernel_1 != null);
    try std.testing.expectEqual(@as(u32, 0xc004_f61e), hit_kernel_1.?.guest_pc);

    const hit_user_1 = cache_inst.lookup(0x0001_0000, 0x8000_1111);
    try std.testing.expect(hit_user_1 != null);
    try std.testing.expectEqual(@as(u32, 0x0001_0000), hit_user_1.?.guest_pc);

    // 4. Context switch: satp changes to 0x80002222 (Process 2).
    // Global kernel block MUST still hit; Process 1 user block MUST miss.
    const hit_kernel_2 = cache_inst.lookup(0xc004_f61e, 0x8000_2222);
    try std.testing.expect(hit_kernel_2 != null);
    try std.testing.expectEqual(@as(u32, 0xc004_f61e), hit_kernel_2.?.guest_pc);

    const hit_user_2 = cache_inst.lookup(0x0001_0000, 0x8000_2222);
    try std.testing.expect(hit_user_2 == null);
}

test "Dynarec Zihintpause instruction decoding and verification" {
    // 0x0100000F is standard RISC-V PAUSE (fence w, 0).
    const pause_dec = decoder_rv32.decode(0x0100_000f);
    try std.testing.expectEqual(decoder_rv32.Instruction.pause, pause_dec.insn);

    // Regular fence (e.g. fence rw, rw: 0x0FF0000F) must decode as .fence.
    const fence_dec = decoder_rv32.decode(0x0ff0_000f);
    try std.testing.expectEqual(decoder_rv32.Instruction.fence, fence_dec.insn);
}

test "Dynamic direct RAM mapping region resolution" {
    var tlb: softtlb_mod.SoftTlb = undefined;
    const gpa_base: usize = 0x8000_0000;
    const hpa_base: usize = 0xe000_0000;
    const ram_size: usize = 512 * 1024 * 1024;
    tlb.initOnPtr(gpa_base, hpa_base, ram_size);

    // 1. Direct physical RAM address in direct window [0x80000000, 0xA0000000).
    const ram_region = tlb.getDirectMappingRegion(0x8000_1000);
    try std.testing.expect(ram_region != null);
    try std.testing.expectEqual(
        @as(u32, 0x8000_0000),
        ram_region.?.vaddr_start,
    );
    try std.testing.expectEqual(@as(u32, 0xa000_0000), ram_region.?.vaddr_end);
    try std.testing.expectEqual(hpa_base, ram_region.?.hpa_start);

    // 2. Verified Sv32 superpage mapping [0xC0000000, 0xC0400000).
    tlb.satp = 0x8000_0000;
    tlb.privilege_mode = 1;
    const slot = (0xc001_7bc4 >> 22) &
        (softtlb_mod.MAX_CONTIGUOUS_REGIONS - 1);
    tlb.contiguous_regions[slot] = .{
        .vaddr_start = 0xc000_0000,
        .vaddr_end = 0xc040_0000,
        .hpa_start = hpa_base,
        .flags = 0x0f,
        .valid = true,
    };
    const kernel_region = tlb.getDirectMappingRegion(0xc001_7bc4);
    try std.testing.expect(kernel_region != null);
    try std.testing.expectEqual(
        @as(u32, 0xc000_0000),
        kernel_region.?.vaddr_start,
    );
    try std.testing.expectEqual(
        @as(u32, 0xc040_0000),
        kernel_region.?.vaddr_end,
    );
    try std.testing.expectEqual(hpa_base, kernel_region.?.hpa_start);

    // 3. MMIO regions must return null (no direct RAM fast-path).
    try std.testing.expect(tlb.getDirectMappingRegion(0x1000_0000) == null);
    try std.testing.expect(tlb.getDirectMappingRegion(0x0c00_0000) == null);
    try std.testing.expect(tlb.getDirectMappingRegion(0x0000_0000) == null);
}

test "Dynarec privilege checks and architectural exception synchronization" {
    var vcpu = vcpu_mod.VCpu{ .id = 0, .pc = 0x8000_0000 };
    var tlb: softtlb_mod.SoftTlb = undefined;
    tlb.initOnPtr(0x8000_0000, 0x8000_0000, 16 * 1024 * 1024);

    var uart = vuart_mod.VirtualUart{};
    var timer = vtimer_mod.VirtualTimer{};
    var pic = vpic_mod.VirtualPlic{};
    var bus = bus_mod.Bus{
        .uart = &uart,
        .timer = &timer,
        .pic = &pic,
    };

    const eng = try std.testing.allocator.create(engine_mod.Engine);
    defer std.testing.allocator.destroy(eng);
    var jit_buffer: [4096]u8 align(4096) = undefined;
    eng.initOnPtr(&jit_buffer, &vcpu, &tlb, &bus);

    // 1. User mode write to supervisor CSR satp (0x180) -> Cause 2.
    vcpu.privilege_mode = vcpu_mod.PRIV_USER;
    vcpu.medeleg = 0xffff;
    vcpu.stvec = 0x8000_0000;
    const csrw_satp = decoder_rv32.decode(0x1805_1073);
    _ = eng.executeDecoded(csrw_satp, 0x1805_1073, 0x1000);
    try std.testing.expectEqual(@as(u32, 2), vcpu.scause);
    try std.testing.expectEqual(@as(u32, 0x1000), vcpu.sepc);

    // 2. Write to read-only CSR cycle (0xC00) in M-mode -> Cause 2.
    vcpu.privilege_mode = vcpu_mod.PRIV_MACHINE;
    vcpu.mcause = 0;
    const csrw_cycle = decoder_rv32.decode(0xc005_1073);
    _ = eng.executeDecoded(csrw_cycle, 0xc005_1073, 0x2000);
    try std.testing.expectEqual(@as(u32, 2), vcpu.mcause);
    try std.testing.expectEqual(@as(u32, 0x2000), vcpu.mepc);

    // 3. sret in U-mode -> Cause 2.
    vcpu.privilege_mode = vcpu_mod.PRIV_USER;
    vcpu.scause = 0;
    const sret_insn = decoder_rv32.decode(0x1020_0073);
    _ = eng.executeDecoded(sret_insn, 0x1020_0073, 0x3000);
    try std.testing.expectEqual(@as(u32, 2), vcpu.scause);
    try std.testing.expectEqual(@as(u32, 0x3000), vcpu.sepc);

    // 4. mret in S-mode -> Cause 2.
    vcpu.privilege_mode = vcpu_mod.PRIV_SUPERVISOR;
    vcpu.scause = 0;
    const mret_insn = decoder_rv32.decode(0x3020_0073);
    _ = eng.executeDecoded(mret_insn, 0x3020_0073, 0x4000);
    try std.testing.expectEqual(@as(u32, 2), vcpu.scause);
    try std.testing.expectEqual(@as(u32, 0x4000), vcpu.sepc);

    // 5. sfence.vma in U-mode -> Cause 2.
    vcpu.privilege_mode = vcpu_mod.PRIV_USER;
    vcpu.scause = 0;
    const sfence_insn = decoder_rv32.decode(0x1200_0073);
    _ = eng.executeDecoded(sfence_insn, 0x1200_0073, 0x5000);
    try std.testing.expectEqual(@as(u32, 2), vcpu.scause);
    try std.testing.expectEqual(@as(u32, 0x5000), vcpu.sepc);

    // 6. satp write with mstatus.TVM = 1 in S-mode -> Cause 2.
    vcpu.privilege_mode = vcpu_mod.PRIV_SUPERVISOR;
    vcpu.mstatus = riscv.MSTATUS.TVM;
    vcpu.scause = 0;
    _ = eng.executeDecoded(csrw_satp, 0x1805_1073, 0x6000);
    try std.testing.expectEqual(@as(u32, 2), vcpu.scause);
    try std.testing.expectEqual(@as(u32, 0x6000), vcpu.sepc);

    // 7. sfence.vma with mstatus.TVM = 1 in S-mode -> Cause 2.
    vcpu.privilege_mode = vcpu_mod.PRIV_SUPERVISOR;
    vcpu.mstatus = riscv.MSTATUS.TVM;
    vcpu.scause = 0;
    _ = eng.executeDecoded(sfence_insn, 0x1200_0073, 0x7000);
    try std.testing.expectEqual(@as(u32, 2), vcpu.scause);
    try std.testing.expectEqual(@as(u32, 0x7000), vcpu.sepc);

    // 8. wfi in U-mode -> Cause 2.
    vcpu.privilege_mode = vcpu_mod.PRIV_USER;
    vcpu.scause = 0;
    const wfi_insn = decoder_rv32.decode(0x1050_0073);
    _ = eng.executeDecoded(wfi_insn, 0x1050_0073, 0x8000);
    try std.testing.expectEqual(@as(u32, 2), vcpu.scause);
    try std.testing.expectEqual(@as(u32, 0x8000), vcpu.sepc);

    // 9. wfi with mstatus.TW = 1 in S-mode -> Cause 2.
    vcpu.privilege_mode = vcpu_mod.PRIV_SUPERVISOR;
    vcpu.mstatus = riscv.MSTATUS.TW;
    vcpu.scause = 0;
    _ = eng.executeDecoded(wfi_insn, 0x1050_0073, 0x9000);
    try std.testing.expectEqual(@as(u32, 2), vcpu.scause);
    try std.testing.expectEqual(@as(u32, 0x9000), vcpu.sepc);

    // 10. sret with mstatus.TSR = 1 in S-mode -> Cause 2.
    vcpu.privilege_mode = vcpu_mod.PRIV_SUPERVISOR;
    vcpu.mstatus = riscv.MSTATUS.TSR;
    vcpu.scause = 0;
    _ = eng.executeDecoded(sret_insn, 0x1020_0073, 0xa000);
    try std.testing.expectEqual(@as(u32, 2), vcpu.scause);
    try std.testing.expectEqual(@as(u32, 0xa000), vcpu.sepc);
}

test "RV32 floating-point (F/D) decoding, decompression and emission" {
    const fsd_raw: u32 = 0x02853c27;
    const fsd_dec = decoder_rv32.decode(fsd_raw);
    try std.testing.expectEqual(
        decoder_rv32.Instruction{
            .fsd = .{ .rs1 = 10, .rs2 = 8, .offset = 56 },
        },
        fsd_dec.insn,
    );
    try std.testing.expectEqual(fsd_raw, emitter_rv64.fsd(10, 8, 56));

    const fld_raw: u32 = 0x04013007;
    const fld_dec = decoder_rv32.decode(fld_raw);
    try std.testing.expectEqual(
        decoder_rv32.Instruction{ .fld = .{ .rd = 0, .rs1 = 2, .offset = 64 } },
        fld_dec.insn,
    );
    try std.testing.expectEqual(fld_raw, emitter_rv64.fld(0, 2, 64));

    const flw_raw: u32 = 0x01052087;
    const flw_dec = decoder_rv32.decode(flw_raw);
    try std.testing.expectEqual(
        decoder_rv32.Instruction{
            .flw = .{ .rd = 1, .rs1 = 10, .offset = 16 },
        },
        flw_dec.insn,
    );
    try std.testing.expectEqual(flw_raw, emitter_rv64.flw(1, 10, 16));

    const fsw_raw: u32 = 0x0025ac27;
    const fsw_dec = decoder_rv32.decode(fsw_raw);
    try std.testing.expectEqual(
        decoder_rv32.Instruction{
            .fsw = .{ .rs1 = 11, .rs2 = 2, .offset = 24 },
        },
        fsw_dec.insn,
    );
    try std.testing.expectEqual(fsw_raw, emitter_rv64.fsw(11, 2, 24));

    const c_fld_dec = decoder_rv32.decode(@as(u16, 0x25a0));
    try std.testing.expect(c_fld_dec.insn == .fld);

    const fadd_s = decoder_rv32.decode(0x0020f053);
    try std.testing.expectEqual(
        decoder_rv32.Instruction{ .fp_op = .{ .raw = 0x0020f053 } },
        fadd_s.insn,
    );

    const fmul_d = decoder_rv32.decode(0x1220f053);
    try std.testing.expectEqual(
        decoder_rv32.Instruction{ .fp_op = .{ .raw = 0x1220f053 } },
        fmul_d.insn,
    );

    const fmadd_s = decoder_rv32.decode(0x1a20f043);
    try std.testing.expectEqual(
        decoder_rv32.Instruction{ .fp_op = .{ .raw = 0x1a20f043 } },
        fmadd_s.insn,
    );

    const fsqrt_s = decoder_rv32.decode(0x5800f053);
    try std.testing.expectEqual(
        decoder_rv32.Instruction{ .fp_op = .{ .raw = 0x5800f053 } },
        fsqrt_s.insn,
    );

    const feq_s = decoder_rv32.decode(0xa0102553);
    try std.testing.expectEqual(
        decoder_rv32.Instruction{ .fp_op = .{ .raw = 0xa0102553 } },
        feq_s.insn,
    );

    const fcvt_w_s = decoder_rv32.decode(0xc0000553);
    try std.testing.expectEqual(
        decoder_rv32.Instruction{ .fp_op = .{ .raw = 0xc0000553 } },
        fcvt_w_s.insn,
    );
}

test "Dynarec RV32I logical, shift, comparison and branch emission" {
    const cache_inst = try std.testing.allocator.create(cache_mod.Cache);
    defer std.testing.allocator.destroy(cache_inst);
    var raw_pool: [4096]u8 align(4096) = undefined;
    cache_inst.initOnPtr(&raw_pool);
    const tb = try cache_inst.allocateBlock(0x8000_0000, 0, false, 512);
    var off: usize = 0;

    emitter_rv64.emit(tb.host_code, &off, emitter_rv64.sllw(10, 11, 12));
    emitter_rv64.emit(tb.host_code, &off, emitter_rv64.srlw(10, 11, 12));
    emitter_rv64.emit(tb.host_code, &off, emitter_rv64.sraw(10, 11, 12));
    emitter_rv64.emit(tb.host_code, &off, emitter_rv64.slliw(10, 11, 4));
    emitter_rv64.emit(tb.host_code, &off, emitter_rv64.srliw(10, 11, 4));
    emitter_rv64.emit(tb.host_code, &off, emitter_rv64.sraiw(10, 11, 4));
    emitter_rv64.emit(tb.host_code, &off, emitter_rv64.slt(10, 11, 12));
    emitter_rv64.emit(tb.host_code, &off, emitter_rv64.sltu(10, 11, 12));
    emitter_rv64.emit(tb.host_code, &off, emitter_rv64.xor_(10, 11, 12));
    emitter_rv64.emit(tb.host_code, &off, emitter_rv64.or_(10, 11, 12));
    emitter_rv64.emit(tb.host_code, &off, emitter_rv64.and_(10, 11, 12));
    emitter_rv64.emit(tb.host_code, &off, emitter_rv64.beq(10, 11, 28));
    emitter_rv64.emit(tb.host_code, &off, emitter_rv64.bne(10, 11, 28));
    emitter_rv64.emit(tb.host_code, &off, emitter_rv64.blt(10, 11, 28));
    emitter_rv64.emit(tb.host_code, &off, emitter_rv64.bge(10, 11, 28));
    emitter_rv64.emit(tb.host_code, &off, emitter_rv64.bltu(10, 11, 28));
    emitter_rv64.emit(tb.host_code, &off, emitter_rv64.bgeu(10, 11, 28));

    try std.testing.expectEqual(@as(usize, 68), off);
}
