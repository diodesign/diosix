// Host Information Formatting: Version Strings and `dsx host info` Output.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const api = @import("../api.zig");
const common = @import("../common.zig");

const KB_PER_MB = common.KB_PER_MB;
const sanitizeJsonStr = common.sanitizeJsonStr;

/// Longest `major.minor.patch` string: three `u16` values of up to five
/// digits each plus two dots.
pub const MAX_VERSION_STR_LEN: usize = 3 * 5 + 2;

/// Formats the CalVer string into `buf`; a buffer shorter than
/// `MAX_VERSION_STR_LEN` is reported and yields an empty string.
pub fn formatVersionChannel(
    buf: []u8,
    major: u16,
    minor: u16,
    patch: u16,
) []const u8 {
    const result = if (patch > 0)
        std.fmt.bufPrint(buf, "{d}.{d}.{d}", .{ major, minor, patch })
    else
        std.fmt.bufPrint(buf, "{d}.{d}", .{ major, minor });
    return result catch |err| {
        common.printFmt(
            "Error: Cannot format version string ({s}).\n",
            .{@errorName(err)},
        );
        return "";
    };
}

/// Extracts the git branch from a hypervisor `build_desc` string
/// (e.g., `"Version 26.1 (beta) main/6f19e11 ..."` -> `"main"`).
pub fn extractBuildBranch(build_desc: []const u8) []const u8 {
    var tok_it = std.mem.tokenizeScalar(u8, build_desc, ' ');
    _ = tok_it.next() orelse return ""; // Skip "Version".
    _ = tok_it.next() orelse return ""; // Skip version number.
    var tok = tok_it.next() orelse return "";
    if (tok.len > 0 and tok[0] == '(') {
        tok = tok_it.next() orelse return ""; // Skip "(channel)".
    }
    if (std.mem.lastIndexOfScalar(u8, tok, '/')) |slash| {
        if (slash > 0) return tok[0..slash];
    }
    return "";
}

/// Formats `dsx host info` as text or JSON. The caller owns the returned
/// slice and frees it with `allocator`.
pub fn allocHostInfo(
    allocator: std.mem.Allocator,
    info: api.HypervisorInfo,
    json_mode: bool,
) ![]u8 {
    var ver_buf: [MAX_VERSION_STR_LEN]u8 = undefined;
    const ver_str = formatVersionChannel(
        &ver_buf,
        info.version_major,
        info.version_minor,
        info.version_patch,
    );
    const channel_str = if ((info.version_minor % 2) == 0) "stable" else "beta";
    const raw_commit = std.mem.sliceTo(&info.build_commit, 0);
    const raw_isa = std.mem.sliceTo(&info.host_cpu_isa, 0);
    const raw_build = std.mem.sliceTo(&info.build_desc, 0);
    const raw_branch = extractBuildBranch(raw_build);

    // The branch is a token of `build_desc`, so that field's size bounds it.
    var branch_buf: [api.BUILD_DESC_LEN]u8 = undefined;
    var commit_buf: [api.BUILD_COMMIT_LEN]u8 = undefined;
    var isa_buf: [api.HOST_CPU_ISA_LEN]u8 = undefined;
    const branch_str = sanitizeJsonStr(&branch_buf, raw_branch);
    const commit_str = sanitizeJsonStr(&commit_buf, raw_commit);
    const isa_str = sanitizeJsonStr(&isa_buf, raw_isa);

    const feat = info.features;
    const HvFeat = api.HypervisorFeature;

    if (json_mode) {
        const charter_sealed =
            if ((feat & HvFeat.CHARTER_SEALED) != 0) "true" else "false";
        const json_fmt =
            "{{\"version\":\"{s}\",\"version_major\":{d}," ++
            "\"version_minor\":{d},\"version_patch\":{d}," ++
            "\"channel\":\"{s}\",\"branch\":\"{s}\",\"commit\":\"{s}\"," ++
            "\"abi\":\"{d}.{d}.{d}\",\"cores\":{d},\"isa\":\"{s}\"," ++
            "\"total_ram_kb\":{d},\"free_ram_kb\":{d}," ++
            "\"hv_reserved_bytes\":{d},\"hv_heap_free_bytes\":{d}," ++
            "\"features\":{d},\"charter_sealed\":{s}}}\n";
        return allocator.print(json_fmt, .{
            ver_str,
            info.version_major,
            info.version_minor,
            info.version_patch,
            channel_str,
            if (branch_str.len > 0) branch_str else "unknown",
            if (commit_str.len > 0) commit_str else "release",
            info.abi_version_major,
            info.abi_version_minor,
            info.abi_version_patch,
            info.host_physical_cores,
            isa_str,
            info.host_total_ram_kb,
            info.host_free_ram_kb,
            info.hv_reserved_bytes,
            info.hv_heap_free_bytes,
            info.features,
            charter_sealed,
        });
    }

    const hw_mark: u8 = if ((feat & HvFeat.HARDWARE_VIRT) != 0) 'x' else ' ';
    const s2_mark: u8 = if ((feat & HvFeat.STAGE2_PAGING) != 0) 'x' else ' ';
    const dy_mark: u8 = if ((feat & HvFeat.DYNAREC) != 0) 'x' else ' ';
    const vs_mark: u8 = if ((feat & HvFeat.VIRTIO_VSOCK) != 0) 'x' else ' ';
    const cs_mark: u8 = if ((feat & HvFeat.CHARTER_SEALED) != 0) 'x' else ' ';

    return allocator.print(
        \\Hypervisor build : {s}
        \\Footprint        : {d} KB reserved, {d} KB free
        \\ABI version      : {d}.{d}.{d}
        \\Host cores       : {d} physical hart(s) {s}
        \\Host RAM         : {d} MB total / {d} MB free
        \\Timer frequency  : {d} Hz
        \\Capabilities     :
        \\  [{c}] Hardware H-extension (nested virtualization)
        \\  [{c}] Stage-2 Sv39x4 paging
        \\  [{c}] Cross-arch JIT dynamic recompilation
        \\  [{c}] VirtIO-vsock (AF_VSOCK in-hypervisor networking)
        \\  [{c}] Constitutional Charter sealed in M-mode
        \\
    , .{
        if (raw_build.len > 0) raw_build else "n/a",
        info.hv_reserved_bytes / 1024,
        info.hv_heap_free_bytes / 1024,
        info.abi_version_major,
        info.abi_version_minor,
        info.abi_version_patch,
        info.host_physical_cores,
        if (isa_str.len > 0) isa_str else "",
        info.host_total_ram_kb / KB_PER_MB,
        info.host_free_ram_kb / KB_PER_MB,
        info.host_timer_freq_hz,
        hw_mark,
        s2_mark,
        dy_mark,
        vs_mark,
        cs_mark,
    });
}

/// Buffer-based form of `allocHostInfo`. Prefer the allocating version; this
/// remains for callers that supply their own buffer. A formatting failure or
/// an undersized buffer is reported and yields an empty slice.
pub fn formatHostInfo(
    buf: []u8,
    info: api.HypervisorInfo,
    json_mode: bool,
) []const u8 {
    const allocator = std.heap.page_allocator;
    const text = allocHostInfo(allocator, info, json_mode) catch |err| {
        common.printFmt(
            "Error: Cannot format host info ({s}).\n",
            .{@errorName(err)},
        );
        return "";
    };
    defer allocator.free(text);
    if (text.len > buf.len) {
        common.printFmt(
            "Error: Host info ({d} bytes) exceeds the {d}-byte buffer.\n",
            .{ text.len, buf.len },
        );
        return "";
    }
    @memcpy(buf[0..text.len], text);
    return buf[0..text.len];
}

test "host: formatVersionChannel formats CalVer strings" {
    std.testing.refAllDecls(@This());
    var buf: [MAX_VERSION_STR_LEN]u8 = undefined;
    try std.testing.expectEqualStrings(
        "26.1",
        formatVersionChannel(&buf, 26, 1, 0),
    );
    try std.testing.expectEqualStrings(
        "26.2.1",
        formatVersionChannel(&buf, 26, 2, 1),
    );
    try std.testing.expectEqualStrings(
        "65535.65535.65535",
        formatVersionChannel(&buf, 65535, 65535, 65535),
    );
}

test "host: allocHostInfo renders text and JSON without a size cap" {
    const allocator = std.testing.allocator;
    const info = api.HypervisorInfo{
        .version_major = 26,
        .version_minor = 2,
        .version_patch = 1,
        .host_physical_cores = 4,
    };
    const text = try allocHostInfo(allocator, info, false);
    defer allocator.free(text);
    try std.testing.expect(
        std.mem.startsWith(u8, text, "Hypervisor build : n/a\n"),
    );
    try std.testing.expect(std.mem.indexOf(u8, text, "Host cores") != null);

    const json = try allocHostInfo(allocator, info, true);
    defer allocator.free(json);
    try std.testing.expect(
        std.mem.indexOf(u8, json, "\"version\":\"26.2.1\"") != null,
    );
    try std.testing.expect(std.mem.endsWith(u8, json, "}\n"));
}
