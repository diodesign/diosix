// Diosix hypervisor early boot and CPU initialization.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const main = @import("../main.zig");
const debug = @import("debug.zig");
const riscv = @import("../hardware/native/cpu/riscv64/mod.zig");
const atomic = @import("atomic.zig");
const dt = @import("dt.zig");
const guest_dtb_builder = @import("guest/dtb.zig");
const physmem = @import("physmem.zig");
const scheduler = @import("scheduler.zig");
const guest = @import("guest.zig");
const loader = @import("loader.zig");
const pcore = @import("pcore.zig");
const sv39x4 = @import("../hardware/native/cpu/riscv64/sv39x4.zig");
const sbi = @import("sbi.zig");
const elf_spec = @import("interface").elf;
const emulation = @import("emulation.zig");
const drivers = @import("drivers.zig");
const config = @import("config");

extern const banner: [*:0]const u8;
extern const project_version: [*:0]const u8;
extern const git_branch: [*:0]const u8;
extern const git_revision: [*:0]const u8;
extern const build_date: [*:0]const u8;
extern const build_user: [*:0]const u8;
extern const build_hostname: [*:0]const u8;
extern const zig_version: [*:0]const u8;
extern const cpu_arch: [*:0]const u8;

// Root VM linker symbols.
extern const __rootvm_start: u8;
extern const __rootvm_end: u8;

pub const MIN_HOST_RAM_SIZE_BYTES: usize = 256 * 1024 * 1024;
pub const MIN_ROOT_VM_RAM_SIZE_BYTES: usize =
    @as(usize, config.root_ram_min_mb) * 1024 * 1024;
pub const MAX_ROOT_VM_RAM_SIZE_BYTES: usize =
    @as(usize, config.root_ram_max_mb) * 1024 * 1024;
pub const ROOT_RAM_HOST_DIVISOR: usize =
    @max(1, @as(usize, config.root_ram_divisor));
pub const ROOT_VM_RAM_SIZE_BYTES: usize = MAX_ROOT_VM_RAM_SIZE_BYTES;
pub const TEST_ROOT_VM_RAM_SIZE_BYTES: usize = 2 * 1024 * 1024;
pub const TEST_ROOT_VM_PAGE_ORDER: u8 = 9;
pub const DEFAULT_GUEST_GPA_BASE: usize = 0x80000000;
pub const MIN_ROOT_VM_VCPU_COUNT: usize = 1;
pub const MAX_ROOT_VM_VCPU_COUNT: usize =
    @max(1, @as(usize, config.root_vcpus_max));
pub const ROOT_VM_VCPU_COUNT: usize = MAX_ROOT_VM_VCPU_COUNT;
pub const RV32_DTB_GPA_OFFSET: usize = 0x04000000;
pub const GUEST_DTB_TAIL_RESERVE_BYTES: usize = 1024 * 1024;
pub const MAX_HOST_BOOTARGS_LEN: usize = 512;

/// Computes Root VM RAM allocation from total host physical RAM.
pub fn computeRootVmRamBytes(total_host_ram_bytes: usize) usize {
    if (total_host_ram_bytes == 0) return MIN_ROOT_VM_RAM_SIZE_BYTES;
    const align_2mb: usize = 2 * 1024 * 1024;
    if (total_host_ram_bytes < MIN_HOST_RAM_SIZE_BYTES) {
        const half = (total_host_ram_bytes / 2) & ~(align_2mb - 1);
        return @max(align_2mb, half);
    }
    const scaled =
        (total_host_ram_bytes / ROOT_RAM_HOST_DIVISOR) & ~(align_2mb - 1);
    return std.math.clamp(
        scaled,
        MIN_ROOT_VM_RAM_SIZE_BYTES,
        MAX_ROOT_VM_RAM_SIZE_BYTES,
    );
}

/// Computes Root VM virtual CPU count from total discovered host CPUs.
pub fn computeRootVmVcpuCount(host_cpu_count: usize) usize {
    if (host_cpu_count == 0) return MAX_ROOT_VM_VCPU_COUNT;
    return std.math.clamp(
        host_cpu_count,
        MIN_ROOT_VM_VCPU_COUNT,
        MAX_ROOT_VM_VCPU_COUNT,
    );
}

/// Sanitizes host-supplied `/chosen/bootargs` by stripping control characters,
/// collapsing consecutive whitespace, and bounding length to `buf.len`.
pub fn sanitizeBootargs(buf: []u8, raw: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    var out_len: usize = 0;
    var prev_space: bool = false;
    for (trimmed) |ch| {
        if (out_len >= buf.len) break;
        const is_ctrl = (ch < 0x20 or ch >= 0x7f);
        const norm: u8 = if (is_ctrl or ch == ' ') ' ' else ch;
        if (norm == ' ') {
            if (prev_space) continue;
            prev_space = true;
        } else {
            prev_space = false;
        }
        buf[out_len] = norm;
        out_len += 1;
    }
    return std.mem.trimEnd(u8, buf[0..out_len], " ");
}

// Global hypervisor state and resources.
pub const SystemContext = struct {
    device_tree: ?*dt.DeviceTree,
    root_vm: ?*guest.Guest,
};

pub var system_ctx_locked = atomic.LockPayload(?*SystemContext).init(
    "Global system context",
    null,
);

fn discoverHostPeripherals(device_tree: *const dt.DeviceTree) !void {
    var dt_it = device_tree.iter("/", 10);
    while (dt_it.next()) |path| {
        const compat_prop = device_tree.getProperty(path, "compatible") catch
            continue;
        const compat_text = compat_prop.asText() catch continue;

        if (std.mem.indexOf(u8, compat_text, "clint") != null or
            std.mem.indexOf(u8, compat_text, "sifive,clint0") != null)
        {
            if (try device_tree.readAddress(path)) |addr| {
                riscv.clint_base = addr;
            }
        } else if (std.mem.indexOf(u8, compat_text, "ns16550a") != null or
            std.mem.indexOf(u8, compat_text, "uart") != null)
        {
            if (try device_tree.readAddress(path)) |addr| {
                riscv.uart_base = addr;
            }
        } else if (std.mem.indexOf(u8, compat_text, "sifive,test") != null) {
            if (try device_tree.readAddress(path)) |addr| {
                riscv.test_device_base = addr;
            }
        } else if (std.mem.indexOf(u8, compat_text, "plic") != null or
            std.mem.indexOf(u8, compat_text, "sifive,plic") != null)
        {
            if (try device_tree.readAddress(path)) |addr| {
                riscv.plic_base = addr;
            }
        }
    }
}

/// Core initialization logic for the boot CPU.
pub fn bootCpuInit(cpu_allocator: std.mem.Allocator, dtb: [*]u8) !void {
    var guest_hart_ids = blk: {
        var ids: [pcore.TABLE_ROWS]usize = undefined;
        for (0..pcore.TABLE_ROWS) |i| {
            ids[i] = i;
        }
        break :blk ids;
    };
    const ver_str = std.mem.trim(u8, std.mem.span(project_version), " \t\r\n");
    const parsed_ver = sbi.parseVersionString(ver_str);
    const channel = if ((parsed_ver.minor % 2) == 0) "stable" else "beta";
    debug.printf("\n{s}\n", .{banner});
    debug.printf(
        "Version {s} ({s}) {s}/{s} {s} {s}@{s} (Zig {s} {s})\n\n",
        .{
            ver_str,    channel,        git_branch,  git_revision, build_date,
            build_user, build_hostname, zig_version, cpu_arch,
        },
    );

    const system_ctx_guard = system_ctx_locked.acquire();
    defer system_ctx_guard.release();

    const system_ctx_ptr = system_ctx_guard.get();
    const ctx = try cpu_allocator.create(SystemContext);
    ctx.* = .{ .device_tree = null, .root_vm = null };

    errdefer {
        if (ctx.device_tree) |t| t.deinit();
        if (ctx.root_vm) |r| r.deinit();
        cpu_allocator.destroy(ctx);
        system_ctx_ptr.* = null;
    }

    const pre_parse_dtb = try dt.DeviceTreeBlob.init(cpu_allocator, dtb);
    defer pre_parse_dtb.deinit();

    const device_tree = try pre_parse_dtb.parse();
    ctx.device_tree = device_tree;

    if (!builtin.is_test) {
        try discoverHostPeripherals(device_tree);
    }

    if (riscv.clint_base) |addr| {
        debug.printf("Discovered CLINT at HPA 0x{x}\n", .{addr});
    }
    if (riscv.uart_base) |addr| {
        debug.printf("Discovered UART at HPA 0x{x}\n", .{addr});
    }
    if (riscv.test_device_base) |addr| {
        debug.printf("Discovered Test/Poweroff device at HPA 0x{x}\n", .{addr});
    }
    if (riscv.plic_base) |addr| {
        debug.printf("Discovered PLIC at HPA 0x{x}\n", .{addr});
    }

    const host_cpu_count = device_tree.countCpus();
    var rootvm_ram_size: usize = TEST_ROOT_VM_RAM_SIZE_BYTES;
    var rootvm_hpa_base: usize = 0;
    var rootvm_region: physmem.Region = undefined;

    if (!builtin.is_test) {
        try physmem.discoverRegions(device_tree);
        rootvm_ram_size = computeRootVmRamBytes(
            physmem.getDiscoveredRamBytes(),
        );
        rootvm_region = try physmem.findContiguousRegion(rootvm_ram_size);
        rootvm_hpa_base = rootvm_region.base;
    } else {
        rootvm_hpa_base = try physmem.allocPageSelection(
            TEST_ROOT_VM_PAGE_ORDER,
        );
        rootvm_region = .{ .base = rootvm_hpa_base, .size = rootvm_ram_size };
    }

    try riscv.auditCpuFeatures();
    drivers.init();

    if (!builtin.is_test) {
        try physmem.init(device_tree, rootvm_region);
    }

    scheduler.init();

    const rootvm_elf_base = if (builtin.is_test)
        test_rootvm_start
    else
        @intFromPtr(&__rootvm_start);
    const rootvm_elf_size = if (builtin.is_test)
        test_rootvm_end - rootvm_elf_base
    else
        @intFromPtr(&__rootvm_end) - rootvm_elf_base;

    const rootvm_elf = @as(
        [*]const u8,
        @ptrFromInt(rootvm_elf_base),
    )[0..rootvm_elf_size];
    const guest_arch = try loader.Loader.detectArch(rootvm_elf);
    const root_vm_gpa_base: usize = if (guest_arch == .x86_64)
        0
    else if (rootvm_hpa_base >= sv39x4.MAX_GPA)
        DEFAULT_GUEST_GPA_BASE
    else
        rootvm_hpa_base;
    debug.printf(
        "Detected guest VM target architecture: {s}\n",
        .{@tagName(guest_arch)},
    );
    const root_vm = try guest.createGuest(
        cpu_allocator,
        true,
        true,
        null,
        root_vm_gpa_base,
        rootvm_hpa_base,
        rootvm_ram_size,
        guest_arch,
    );
    ctx.root_vm = root_vm;

    @memset(@as([*]u8, @ptrFromInt(rootvm_hpa_base))[0..rootvm_ram_size], 0);

    const entry_point = try loader.Loader.load(root_vm, rootvm_elf);

    const cpu_count: usize = computeRootVmVcpuCount(host_cpu_count);
    debug.printf(
        "Provisioning Root VM with {} virtual CPUs ({} MB RAM)\n",
        .{ cpu_count, rootvm_ram_size / (1024 * 1024) },
    );

    var host_bootargs_buf: [MAX_HOST_BOOTARGS_LEN]u8 = undefined;
    var host_bootargs: []const u8 = "";
    if (device_tree.getProperty("/chosen", "bootargs")) |existing_prop| {
        if (existing_prop.asText()) |txt| {
            host_bootargs = sanitizeBootargs(&host_bootargs_buf, txt);
        } else |_| {}
    } else |_| {}

    var guest_dtb: ?[]u8 = null;
    var guest_dtb_owned_tree: ?*dt.DeviceTree = null;
    defer {
        if (guest_dtb_owned_tree) |tree| tree.deinit();
        if (guest_dtb) |dtb_slice| cpu_allocator.free(dtb_slice);
    }

    if (guest_arch == .aarch64) {
        const arm_dt = try guest_dtb_builder.buildAarch64Dtb(
            cpu_allocator,
            root_vm_gpa_base,
            rootvm_ram_size,
            cpu_count,
            host_bootargs,
        );
        guest_dtb_owned_tree = arm_dt;
        guest_dtb = try arm_dt.toBlob();
    } else {
        guest_dtb = try guest_dtb_builder.buildRiscvGuestDtb(
            cpu_allocator,
            device_tree,
            guest_arch,
            root_vm_gpa_base,
            rootvm_ram_size,
            cpu_count,
            host_bootargs,
            &guest_hart_ids,
        );
    }

    const guest_dtb_slice = guest_dtb.?;
    if (guest_dtb_slice.len > GUEST_DTB_TAIL_RESERVE_BYTES) {
        return error.OutOfBoundsWrite;
    }
    const guest_dtb_gpa = if (guest_arch == .riscv32)
        root_vm_gpa_base + RV32_DTB_GPA_OFFSET
    else
        root_vm_gpa_base + rootvm_ram_size - GUEST_DTB_TAIL_RESERVE_BYTES;
    const guest_dtb_hpa = try root_vm.space.translateGPA(guest_dtb_gpa);

    const rwx_flags = sv39x4.PTEFlags.read |
        sv39x4.PTEFlags.write |
        sv39x4.PTEFlags.execute |
        sv39x4.PTEFlags.valid |
        sv39x4.PTEFlags.accessed |
        sv39x4.PTEFlags.dirty |
        sv39x4.PTEFlags.user;
    try root_vm.space.map(
        guest_dtb_gpa,
        guest_dtb_hpa,
        guest_dtb_slice.len,
        rwx_flags,
    );
    try root_vm.space.copyToGuest(guest_dtb_gpa, guest_dtb_slice);

    debug.printf(
        "Using Root VM image at HPA 0x{x} ({} bytes), entry at GPA 0x{x}\n",
        .{ rootvm_elf_base, rootvm_elf_size, entry_point },
    );

    const is_emulated = (guest_arch != .riscv64);
    for (0..cpu_count) |i| {
        const vcore_id = if (guest_arch == .aarch64) i else guest_hart_ids[i];
        const vc = try root_vm.addVcore(
            vcore_id,
            entry_point,
            guest_dtb_gpa,
            .high,
            null,
        );

        if (is_emulated) {
            try emulation.init(vc);
        }

        if (i == 0) {
            vc.state = .ready;
            scheduler.queue(vc);
        }
    }

    main.global_root_vm = root_vm;
    system_ctx_ptr.* = ctx;
}

// Mock Root VM symbols for tests.
const test_rootvm_data = if (builtin.is_test) blk: {
    var data: [64]u8 = std.mem.zeroes([64]u8);
    @memcpy(
        data[elf_spec.EHDR.IDENT .. elf_spec.EHDR.IDENT + 4],
        elf_spec.MAGIC,
    );
    data[4] = elf_spec.CLASS_64;
    data[5] = elf_spec.DATA_LSB;
    std.mem.writeInt(
        u16,
        data[elf_spec.EHDR.MACHINE..][0..2],
        elf_spec.MACHINE_RISCV,
        .little,
    );
    std.mem.writeInt(
        u64,
        data[elf_spec.EHDR.ENTRY..][0..8],
        0x80000000,
        .little,
    );
    data[elf_spec.EHDR.PHOFF] = 64;
    data[elf_spec.EHDR.PHENTSIZE] = 56;
    data[elf_spec.EHDR.PHNUM] = 0;
    break :blk data;
} else {};
pub var test_rootvm_start: usize = 0;
pub var test_rootvm_end: usize = 0;

test "boot CPU initialization, bootargs forwarding, and resource scaling" {
    const testing = std.testing;
    const allocator = testing.allocator;

    riscv.initMockHardware();

    const ram_size = 1024 * 1024;
    const fake_ram = try allocator.alloc(u8, ram_size);
    defer allocator.free(fake_ram);
    const ram_base = @intFromPtr(fake_ram.ptr);

    const P = dt.DeviceTreeProperty;
    const host_tree = try dt.DeviceTree.init(allocator);
    try host_tree.editProperty(
        "/",
        "#address-cells",
        try P.fromU32(allocator, 2),
    );
    try host_tree.editProperty("/", "#size-cells", try P.fromU32(allocator, 2));
    try host_tree.editProperty(
        "/memory@80000000",
        "device_type",
        try P.fromText(allocator, "memory"),
    );
    try host_tree.editProperty(
        "/memory@80000000",
        "reg",
        try P.fromMultiU64(allocator, &.{ ram_base, ram_size }),
    );
    const args_p = try P.fromText(allocator, "diosix.mode=dev diosix.ui=gui");
    try host_tree.editProperty("/chosen", "bootargs", args_p);
    const host_blob = try host_tree.toBlob();
    host_tree.deinit();
    defer allocator.free(host_blob);
    const test_rootvm_data_buf = try allocator.alloc(u8, 1024);
    defer allocator.free(test_rootvm_data_buf);
    @memcpy(test_rootvm_data_buf[0..test_rootvm_data.len], &test_rootvm_data);
    test_rootvm_start = @intFromPtr(test_rootvm_data_buf.ptr);
    test_rootvm_end = test_rootvm_start + test_rootvm_data_buf.len;
    var phys_test = try physmem.initForTest(allocator, 1024);
    defer phys_test.deinit();
    try bootCpuInit(allocator, host_blob.ptr);

    const system_ctx_guard = system_ctx_locked.acquire();
    defer system_ctx_guard.release();
    const system_ctx_ptr = system_ctx_guard.get();

    try testing.expect(system_ctx_ptr.* != null);
    if (system_ctx_ptr.*) |ctx| {
        if (ctx.device_tree) |tree| {
            const p = try tree.getProperty("/chosen", "bootargs");
            const text = try p.asText();
            const has_con = std.mem.indexOf(u8, text, "console=hvc0") != null;
            const has_arg =
                std.mem.indexOf(u8, text, "diosix.mode=dev diosix.ui=gui") !=
                null;
            try testing.expect(has_con and has_arg);
            tree.deinit();
        }
        if (ctx.root_vm) |g| g.deinit();
        allocator.destroy(ctx);
    }
    system_ctx_ptr.* = null;

    var buf: [32]u8 = undefined;
    const s1 = sanitizeBootargs(&buf, "  diosix.mode=dev\n\tdiosix.ui=gui  ");
    try testing.expectEqualStrings("diosix.mode=dev diosix.ui=gui", s1);
    const raw2 = "diosix.mode=live\x1b[2J  \x7fdiosix.ui=tui";
    const s2 = sanitizeBootargs(&buf, raw2);
    try testing.expectEqualStrings("diosix.mode=live [2J diosix.ui=t", s2);

    const mib: usize = 1024 * 1024;
    const gib: usize = 1024 * mib;
    try testing.expectEqual(128 * mib, computeRootVmRamBytes(512 * mib));
    try testing.expectEqual(128 * mib, computeRootVmRamBytes(1 * gib));
    try testing.expectEqual(192 * mib, computeRootVmRamBytes(1536 * mib));
    try testing.expectEqual(256 * mib, computeRootVmRamBytes(2 * gib));
    try testing.expectEqual(256 * mib, computeRootVmRamBytes(128 * gib));
    try testing.expectEqual(@as(usize, 4), computeRootVmVcpuCount(0));
    try testing.expectEqual(@as(usize, 1), computeRootVmVcpuCount(1));
    try testing.expectEqual(@as(usize, 2), computeRootVmVcpuCount(2));
    try testing.expectEqual(@as(usize, 4), computeRootVmVcpuCount(64));
}
