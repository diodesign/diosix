// Host unit test entrypoint for libdiosix Zig API, governance, and C ABI.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const c = @import("c_diosix");
const lib = @import("lib.zig");
const gov = @import("governance.zig");
const pt = @import("passthrough.zig");
const c_abi = @import("c_abi.zig");

test "libdiosix: wire submodules" {
    _ = lib;
    _ = gov;
    _ = pt;
    _ = c_abi;
    std.testing.refAllDecls(lib);
    std.testing.refAllDecls(gov);
    std.testing.refAllDecls(pt);
    std.testing.refAllDecls(c_abi);
    std.testing.refAllDecls(c_abi.pt);
}

test "libdiosix: C header ABI sizes and offsets match Zig ABI" {
    try std.testing.expectEqual(@sizeOf(lib.HypervisorInfo), @sizeOf(
        c.diosix_hv_info_t,
    ));
    try std.testing.expectEqual(@sizeOf(lib.GuestInfo), @sizeOf(
        c.diosix_guest_info_t,
    ));
    try std.testing.expectEqual(@sizeOf(lib.Event), @sizeOf(c.diosix_event_t));
    try std.testing.expectEqual(@sizeOf(lib.RunArgs), @sizeOf(
        c.diosix_run_args_t,
    ));
    try std.testing.expectEqual(@sizeOf(lib.QuotaArgs), @sizeOf(
        c.diosix_quota_args_t,
    ));
    try std.testing.expectEqual(@sizeOf(lib.CharterArgs), @sizeOf(
        c.diosix_charter_args_t,
    ));
    try std.testing.expectEqual(@sizeOf(lib.MissionArgs), @sizeOf(
        c.diosix_mission_args_t,
    ));
    try std.testing.expectEqual(@sizeOf(lib.MissionVoteArgs), @sizeOf(
        c.diosix_mission_vote_args_t,
    ));

    try std.testing.expectEqual(
        @offsetOf(lib.HypervisorInfo, "build_desc"),
        @offsetOf(c.diosix_hv_info_t, "build_desc"),
    );
    try std.testing.expectEqual(
        @offsetOf(lib.GuestInfo, "delegated_ram_pages"),
        @offsetOf(c.diosix_guest_info_t, "delegated_ram_pages"),
    );
    try std.testing.expectEqual(
        @offsetOf(lib.MissionArgs, "voter_count"),
        @offsetOf(c.diosix_mission_args_t, "voter_count"),
    );
}

test "libdiosix: C ABI error guards and strerror" {
    var ctx: ?*anyopaque = null;
    try std.testing.expectEqual(
        c_abi.ERR_INVALID_ARG,
        c_abi.diosix_open_status(null, &ctx),
    );
    try std.testing.expectEqual(
        c_abi.ERR_NO_DEVICE,
        c_abi.diosix_open_status("/nonexistent/diosix", &ctx),
    );
    try std.testing.expectEqual(
        c_abi.ERR_INVALID_ARG,
        c_abi.diosix_drop_trust(null),
    );
    try std.testing.expectEqual(
        c_abi.ERR_INVALID_ARG,
        c_abi.diosix_wait_event(null, lib.CID_SELF, 0, null),
    );
    try std.testing.expectEqualStrings(
        "ok",
        std.mem.span(c_abi.diosix_strerror(c_abi.OK)),
    );
    try std.testing.expectEqualStrings(
        "would block",
        std.mem.span(c_abi.diosix_strerror(c_abi.ERR_WOULD_BLOCK)),
    );
    try std.testing.expectEqual(
        lib.RunFlags.DMA_TRUSTED,
        @as(u64, c.DIOSIX_RUN_FLAG_DMA_TRUSTED),
    );
    try std.testing.expectEqual(
        lib.MmioPassFlags.QUERY_RAM,
        @as(u64, c.DIOSIX_MMIO_FLAG_QUERY_RAM),
    );
    try std.testing.expectEqual(
        c_abi.ERR_INVALID_ARG,
        c_abi.pt.diosix_map_child_mmio(
            null,
            2,
            0x3000_0000,
            0x3000_0000,
            4096,
            0,
        ),
    );
    try std.testing.expectEqual(
        c_abi.ERR_INVALID_ARG,
        c_abi.pt.diosix_query_child_ram(null, 2, null, null, null),
    );
    try std.testing.expectEqual(
        c_abi.ERR_INVALID_ARG,
        c_abi.pt.diosix_delegate_child_irq(null, 2, 32, 32, 0),
    );
}
