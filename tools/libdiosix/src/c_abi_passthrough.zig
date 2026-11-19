// C ABI bindings for libdiosix device passthrough (MMIO, DMA RAM, IRQ).
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const c_abi = @import("c_abi.zig");

pub export fn diosix_map_child_mmio(
    ctx_raw: ?*anyopaque,
    target_cid: u64,
    host_pa: u64,
    child_gpa: u64,
    size: usize,
    flags: u64,
) callconv(.c) c_int {
    const c = c_abi.getClient(ctx_raw) orelse return c_abi.ERR_INVALID_ARG;
    if (size == 0) return c_abi.ERR_INVALID_ARG;
    c.mapChildMmio(
        @intCast(target_cid),
        host_pa,
        child_gpa,
        size,
        flags,
    ) catch |err| return c_abi.mapErr(err);
    return c_abi.OK;
}

pub export fn diosix_query_child_ram(
    ctx_raw: ?*anyopaque,
    target_cid: u64,
    out_gpa_base: ?*u64,
    out_hpa_base: ?*u64,
    out_size: ?*usize,
) callconv(.c) c_int {
    const c = c_abi.getClient(ctx_raw) orelse return c_abi.ERR_INVALID_ARG;
    if (out_gpa_base == null and out_hpa_base == null and out_size == null) {
        return c_abi.ERR_INVALID_ARG;
    }
    const info = c.queryChildRam(@intCast(target_cid)) catch |err|
        return c_abi.mapErr(err);
    if (out_gpa_base) |p| p.* = info.gpa_base;
    if (out_hpa_base) |p| p.* = info.hpa_base;
    if (out_size) |p| p.* = info.size;
    return c_abi.OK;
}

pub export fn diosix_delegate_child_irq(
    ctx_raw: ?*anyopaque,
    target_cid: u64,
    phys_irq: u32,
    virt_irq: u32,
    flags: u64,
) callconv(.c) c_int {
    const c = c_abi.getClient(ctx_raw) orelse return c_abi.ERR_INVALID_ARG;
    _ = c.delegateChildIrq(
        @intCast(target_cid),
        phys_irq,
        virt_irq,
        flags,
    ) catch |err| return c_abi.mapErr(err);
    return c_abi.OK;
}
