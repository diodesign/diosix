// Diosix Native Dynamic Recompiler & Virtual Hardware Module Interface
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub const vcpu = @import("vcpu.zig");
pub const VCpu = vcpu.VCpu;
pub const PRIV_USER = vcpu.PRIV_USER;
pub const PRIV_SUPERVISOR = vcpu.PRIV_SUPERVISOR;
pub const PRIV_MACHINE = vcpu.PRIV_MACHINE;

pub const SoftTlb = @import("softtlb.zig").SoftTlb;
pub const Engine = @import("engine/dynarec/engine.zig").Engine;
pub const ExitReason = Engine.ExitReason;
pub const Cache = @import("engine/dynarec/cache.zig").Cache;
pub const TranslationBlock =
    @import("engine/dynarec/block.zig").TranslationBlock;
pub const Bus = @import("devices/bus.zig").Bus;
pub const VirtualUart = @import("devices/vuart.zig").VirtualUart;
pub const VirtualTimer = @import("devices/vtimer.zig").VirtualTimer;
pub const VirtualPlic = @import("devices/vpic.zig").VirtualPlic;
pub const VirtioVsock = @import("devices/vsock.zig").VirtioVsock;
pub const VirtioGpu = @import("devices/vgpu.zig").VirtioGpu;
pub const VirtioInput = @import("devices/vinput.zig").VirtioInput;
pub const VsockRouter = @import("devices/vsock.zig").VsockRouter;
pub const global_vsock_router =
    @import("devices/vsock.zig").global_vsock_router;
pub const decoder_rv32 = @import("engine/decoders/rv32.zig");
pub const emitter_rv64 = @import("engine/emitters/rv64.zig");

test {
    _ = @import("vcpu.zig");
    _ = @import("vcpu/csr.zig");
    _ = @import("reservation.zig");
    _ = @import("softtlb.zig");
    _ = @import("softtlb/ops.zig");
    _ = @import("softtlb/walk.zig");
    _ = @import("devices/bus.zig");
    _ = @import("devices/vuart.zig");
    _ = @import("devices/vtimer.zig");
    _ = @import("devices/vpic.zig");
    _ = @import("devices/vsock.zig");
    _ = @import("devices/vsock/router.zig");
    _ = @import("devices/vsock/queues.zig");
    _ = @import("devices/vgpu.zig");
    _ = @import("devices/vgpu/protocol.zig");
    _ = @import("devices/vgpu/commands.zig");
    _ = @import("devices/vinput.zig");
    _ = @import("engine/decoders/aarch64.zig");
    _ = @import("engine/decoders/x86_64.zig");
    _ = @import("engine/decoders/rv32/encoding.zig");
    _ = @import("engine/decoders/rv32c.zig");
    _ = @import("engine/decoders/rv32.zig");
    _ = @import("engine/emitters/rv64.zig");
    _ = @import("engine/dynarec/regalloc.zig");
    _ = @import("engine/dynarec/block.zig");
    _ = @import("engine/dynarec/cache.zig");
    _ = @import("engine/dynarec/emit/alu.zig");
    _ = @import("engine/dynarec/emit/branch.zig");
    _ = @import("engine/dynarec/emit/tlb.zig");
    _ = @import("engine/dynarec/emit/mem.zig");
    _ = @import("engine/dynarec/translator.zig");
    _ = @import("engine/dynarec/interpreter/sys.zig");
    _ = @import("engine/dynarec/interpreter/mem.zig");
    _ = @import("engine/dynarec/interpreter.zig");
    _ = @import("engine/dynarec/engine.zig");
    _ = @import("engine/dynarec/tests/instruction.zig");
    _ = @import("engine/dynarec/tests/privilege.zig");
    std.testing.refAllDecls(@This());
}
