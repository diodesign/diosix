// Diosix Native Dynamic Recompiler & Virtual Hardware Module Interface
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

pub const vcpu = @import("vcpu.zig");
pub const VCpu = vcpu.VCpu;
pub const PRIV_USER = vcpu.PRIV_USER;
pub const PRIV_SUPERVISOR = vcpu.PRIV_SUPERVISOR;
pub const PRIV_MACHINE = vcpu.PRIV_MACHINE;

pub const SoftTlb = @import("softtlb.zig").SoftTlb;
pub const Engine = @import("engine/dynarec/engine.zig").Engine;
pub const ExitReason = @import("engine/dynarec/engine.zig").ExitReason;
pub const Cache = @import("engine/dynarec/cache.zig").Cache;
pub const TranslationBlock = @import("engine/dynarec/block.zig").TranslationBlock;
pub const Bus = @import("devices/bus.zig").Bus;
pub const VirtualUart = @import("devices/vuart.zig").VirtualUart;
pub const VirtualTimer = @import("devices/vtimer.zig").VirtualTimer;
pub const VirtualPlic = @import("devices/vpic.zig").VirtualPlic;
pub const VirtioVsock = @import("devices/vsock.zig").VirtioVsock;
pub const VsockRouter = @import("devices/vsock.zig").VsockRouter;
pub const global_vsock_router = &@import("devices/vsock.zig").global_vsock_router;
pub const decoder_rv32 = @import("engine/decoders/rv32.zig");
pub const emitter_rv64 = @import("engine/emitters/rv64.zig");
