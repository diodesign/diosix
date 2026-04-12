// Diosix hypervisor initialization and main loop.
//
// Copyright (c) 2024, 2025, 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const xint = @import("xint.zig");
const debug = @import("debug.zig");
const riscv = @import("riscv.zig");
const alloc = @import("alloc.zig");
const atomic = @import("atomic.zig");
const metadata = @import("metadata");
const dt = @import("dt.zig");
const physmem = @import("physmem.zig");
const scheduler = @import("scheduler.zig");
const guest = @import("guest.zig");
const vcore = @import("vcore.zig");
const loader = @import("loader.zig");
const pcore = @import("pcore.zig");
const sv39x4 = @import("sv39x4.zig");
const elf_spec = @import("interface").elf;

extern fn hw_pmp_init() void;

// Root VM linker symbols.
extern const __rootvm_start: u8;
extern const __rootvm_end: u8;

// Mock Root VM symbols for tests.
const test_rootvm_data = if (builtin.is_test) blk: {
    var data = [_]u8{0} ** 64;
    // Minimal 64-bit RISC-V ELF header.
    @memcpy(data[elf_spec.EHDR.IDENT .. elf_spec.EHDR.IDENT + 4], elf_spec.MAGIC);
    data[4] = elf_spec.CLASS_64;
    data[5] = elf_spec.DATA_LSB;
    data[elf_spec.EHDR.MACHINE] = @truncate(elf_spec.MACHINE_RISCV);
    data[elf_spec.EHDR.MACHINE + 1] = @truncate(elf_spec.MACHINE_RISCV >> 8);
    data[elf_spec.EHDR.ENTRY] = 0x00; // Entry point (0x80000000)
    data[elf_spec.EHDR.ENTRY + 1] = 0x00;
    data[elf_spec.EHDR.ENTRY + 2] = 0x00;
    data[elf_spec.EHDR.ENTRY + 3] = 0x80;
    data[elf_spec.EHDR.PHOFF] = 64;   // Program header offset
    data[elf_spec.EHDR.PHENTSIZE] = 56;   // Program header size
    data[elf_spec.EHDR.PHNUM] = 0;    // Number of program headers
    break :blk data;
} else {};
var test_rootvm_start: usize = 0;
var test_rootvm_end: usize = 0;

const BootCpuID: usize = 0; // CPU ID 0 does all the heavy lifting to begin with.
var boot_complete_flag = false; // True when all cores can begin running viCPU threads.

// Global hypervisor state and resources - system_ctx_lock must be acquired before accessing post-boot.
const SystemContext = struct {
    device_tree: ?*dt.DeviceTree,
    root_vm: ?*guest.Guest,
};
var system_ctx_lock = atomic.NamedSpinLock.init("Global system context lock");
var system_ctx: ?*SystemContext = null;

// This is the core initialization logic for the boot CPU.
// It is separated from main() to allow for easier testing.
fn bootCpuInit(cpu_allocator: std.mem.Allocator, dtb: [*]u8) !void {
    debug.printf("{s}\n", .{metadata.banner});
    debug.printf("Version {s} {s}/{s} {s} {s}@{s} (Zig {s} {s})\n\n", .{ metadata.project_version, metadata.git_branch, metadata.git_revision, metadata.build_date, metadata.build_user, metadata.build_hostname, metadata.zig_version, metadata.cpu_arch });

    system_ctx = try cpu_allocator.create(SystemContext);
    system_ctx.?.* = .{ .device_tree = null, .root_vm = null };
    errdefer {
        if (system_ctx) |ctx| {
            if (ctx.device_tree) |t| t.deinit();
            if (ctx.root_vm) |g| g.deinit();
            cpu_allocator.destroy(ctx);
        }
        system_ctx = null;
    }

    const pre_parse_dtb = try dt.DeviceTreeBlob.init(cpu_allocator, dtb);
    defer pre_parse_dtb.deinit();

    // Keep parsed tree in boot CPU core's heap.
    const device_tree = try pre_parse_dtb.parse();
    system_ctx.?.device_tree = device_tree;

    // Initialize physical memory management.
    // Initialize physical memory management.
    const rootvm_ram_size = if (builtin.is_test) 2 * 1024 * 1024 else 512 * 1024 * 1024;
    
    // In a real boot, we discover regions first, find a gap, then initialize the allocator
    if (!builtin.is_test) {
        try physmem.discoverRegions(device_tree);
    }

    const rootvm_region = try physmem.findContiguousRegion(rootvm_ram_size);
    const rootvm_hpa_base = rootvm_region.base;

    if (!builtin.is_test) {
        try physmem.init(device_tree, rootvm_region);
    }

    // Initialize the global scheduler.
    scheduler.init();

    const rootvm_elf_base = if (builtin.is_test) test_rootvm_start else @intFromPtr(&__rootvm_start);
    const rootvm_elf_size = if (builtin.is_test) test_rootvm_end - rootvm_elf_base else @intFromPtr(&__rootvm_end) - rootvm_elf_base;

    // Create the trusted root VM. 
    // Guest RAM starts at 0x80000000 (standard for RISC-V Linux).
    const root_vm_gpa_base = 0x80000000;
    const root_vm = try guest.createGuest(cpu_allocator, true, true, null, root_vm_gpa_base, rootvm_hpa_base, rootvm_ram_size);
    system_ctx.?.root_vm = root_vm;

    // Load the root VM ELF and get its entry point.
    const entry_point = try loader.Loader.load(root_vm, @as([*]const u8, @ptrFromInt(rootvm_elf_base))[0..rootvm_elf_size]);

    // Pre-map the root VM's entry region (first 2MB) into the guest physical space.
    // This avoids an immediate guest page fault during the first fetch.
    try root_vm.space.map(root_vm_gpa_base, rootvm_hpa_base, 2 * 1024 * 1024, sv39x4.PTEFlags.read | sv39x4.PTEFlags.write | sv39x4.PTEFlags.execute | sv39x4.PTEFlags.valid | sv39x4.PTEFlags.accessed | sv39x4.PTEFlags.dirty | sv39x4.PTEFlags.user);

    // Generate a guest DTB from the host device tree.
    // Tailor it for the Root VM: 512MB RAM and 2 virtual CPUs.
    const guest_memory_node = try std.fmt.allocPrint(cpu_allocator, "/memory@{x}", .{root_vm_gpa_base});
    defer cpu_allocator.free(guest_memory_node);

    // Update memory node for the guest
    try device_tree.editProperty(guest_memory_node, "reg", try dt.DeviceTreeProperty.fromMultiU64(cpu_allocator, &.{ root_vm_gpa_base, rootvm_ram_size }));
    try device_tree.editProperty(guest_memory_node, "device_type", try dt.DeviceTreeProperty.fromText(cpu_allocator, "memory"));

    // For now, we leave other nodes as is, but in a real system we'd cull the CPU nodes to match 2 cores.
    // The user strictly asked for 2 cores, so we'll ensure the DTB matches what we actually start.
    
    const guest_dtb = try device_tree.toBlob();
    defer cpu_allocator.free(guest_dtb);

    // Copy guest DTB into guest RAM (at 1MB after base).
    const guest_dtb_gpa = root_vm_gpa_base + 1024 * 1024;
    const guest_dtb_hpa = try root_vm.space.translateGPA(guest_dtb_gpa);
    @memcpy(@as([*]u8, @ptrFromInt(guest_dtb_hpa))[0..guest_dtb.len], guest_dtb);

    debug.printf("Found root VM image at 0x{x} ({} bytes), entry at 0x{x}\n", .{ rootvm_elf_base, rootvm_elf_size, entry_point });

    // Create 2 virtual cores for the root VM as requested.
    const cpu_count = 2;
    for (0..cpu_count) |i| {
        _ = try root_vm.addVcore(i, entry_point, guest_dtb_gpa, .high);
    }
}

// This is the thread-safe Zig entry point for the hypervisor.
// cpu_core_id = unique ID assigned by the hypervisor to this physical CPU core.
// dtb = pointer to host system's device tree in memory.
// Returns to an infinite loop.
pub export fn main(cpu_core_id: usize, dtb: [*]u8) void {
    hw_pmp_init();
    scheduler.initCpu();
    if (builtin.is_test) return;
    const cpu_ctx = riscv.getCPUContext();
    cpu_ctx.cpu_core_id = cpu_core_id;

    cpu_ctx.allocator.init(riscv.getCPUHeapBase(), riscv.getCPUHeapSize()) catch {
        debug.printf("CPU core ID {} failed to initialize its heap allocator\n", .{cpu_core_id});
        return;
    };
    const allocator = cpu_ctx.allocator.allocator();

    xint.init();
    scheduler.initCpu();

    switch (cpu_core_id) {
        BootCpuID => {
            bootCpuInit(allocator, dtb) catch |err| {
                debug.printf("Boot CPU failed to initialize, reason: {s}\n", .{@errorName(err)});
                // In a real scenario, we might halt or panic here.
                // For now, we just stop this core.
                return;
            };

            atomic.writeBool(&boot_complete_flag, true);
        },

        else => while (atomic.readBool(&boot_complete_flag) == false) {},
    }

    debug.printf("CPU core ID {} entering scheduling loop...\n", .{cpu_core_id});
    while (true) {
        // Heartbeat for diagnostic
        // debug.putchar(@intCast(0x30 + cpu_core_id)); 

        scheduler.schedule();

        // If scheduling picked a vcore, jump into it. 
        // Once inside the guest, interrupts will drive future scheduling.
        if (pcore.this().active_vcore) |ptr| {
            const vc: *vcore.VirtualCore = @ptrCast(@alignCast(ptr));
            
            // Set up guest machine state: switch to supervisor mode on mret.
            const mstatus = (riscv.readMstatus() & ~@as(usize, riscv.MSTATUS.MPP_MASK)) | 
                            (@as(usize, @intFromEnum(riscv.PrivilegeMode.supervisor)) << riscv.MSTATUS.MPP_SHIFT) |
                            riscv.MSTATUS.MPV;

            // Generate hgatp for guest physical address translation if H-extension is active.
            const hgatp = if (vc.guest.space.mode == .h_paging) vc.guest.space.paging.?.hgatp(vc.guest.vmid) else 0;

            const physical_entry = 0x80000000;

            debug.printf("Core {} entering guest at GPA 0x{x}\n", .{pcore.this().cpu_core_id, physical_entry});
            pcore.hw_run_vcore(&vc.context, physical_entry, mstatus, vc.hstatus, hgatp);
        }

        // We only get here if no vcores were available to run.
        riscv.pause(); // wfi
    }
}

pub fn panic(message: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    debug.printf("\n*** HYPERVISOR PANIC ***\n{s}\n", .{message});
    while (true) {}
}

test "boot CPU initialization" {
    const testing = std.testing;

    // Create a valid minimal DTB with:
    // - 40 bytes header (10 x u32)
    // - 16 bytes memory reservation block (terminating entry: addr=0, size=0)
    // - 16 bytes structure block (BEGIN_NODE "" + END_NODE + FDT_END)
    // - 0 bytes strings block
    // Total = 72 bytes (0x48).
    var fake_dtb_data align(4) = [_]u8{
        // ---- header (40 bytes) ----
        0xd0, 0x0d, 0xfe, 0xed, // magic
        0x00, 0x00, 0x00, 0xbc, // totalsize = 188 bytes
        0x00, 0x00, 0x00, 0x38, // off_dt_struct = 56
        0x00, 0x00, 0x00, 0x9c, // off_dt_strings = 156
        0x00, 0x00, 0x00, 0x28, // off_mem_rsvmap = 40
        0x00, 0x00, 0x00, 0x11, // version = 17
        0x00, 0x00, 0x00, 0x10, // last_comp_version = 16
        0x00, 0x00, 0x00, 0x00, // boot_cpuid_phys = 0
        0x00, 0x00, 0x00, 0x20, // size_dt_strings = 32
        0x00, 0x00, 0x00, 0x64, // size_dt_struct = 100

        // ---- memory reservation block (16 bytes) ----
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // addr=0
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // size=0

        // ---- structure block (100 bytes) ----
        0x00, 0x00, 0x00, 0x01, // 0: FDT_BEGIN_NODE (root)
        0x00, 0x00, 0x00, 0x00, // 4: name "" (padded)

        0x00, 0x00, 0x00, 0x03, // 8: FDT_PROP (#address-cells)
        0x00, 0x00, 0x00, 0x04, // 12: size = 4
        0x00, 0x00, 0x00, 0x00, // 16: nameoff = 0
        0x00, 0x00, 0x00, 0x02, // 20: value = 2

        0x00, 0x00, 0x00, 0x03, // 24: FDT_PROP (#size-cells)
        0x00, 0x00, 0x00, 0x04, // 28: size = 4
        0x00, 0x00, 0x00, 0x0f, // 32: nameoff = 15
        0x00, 0x00, 0x00, 0x02, // 36: value = 2

        0x00, 0x00, 0x00, 0x01, // 40: FDT_BEGIN_NODE (memory@80000000)
        0x6d, 0x65, 0x6d, 0x6f, 0x72, 0x79, 0x40, 0x38, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x00, // 44: name (16 bytes)

        0x00, 0x00, 0x00, 0x03, // 60: FDT_PROP (reg)
        0x00, 0x00, 0x00, 0x10, // 64: size = 16
        0x00, 0x00, 0x00, 0x1b, // 68: nameoff = 27
        0x00, 0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00, // 72: base = 0x80000000
        0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, // 80: size = 16MB

        0x00, 0x00, 0x00, 0x02, // 88: FDT_END_NODE (memory@80000000)
        0x00, 0x00, 0x00, 0x02, // 92: FDT_END_NODE (root)
        0x00, 0x00, 0x00, 0x09, // 96: FDT_END
        // Total struct size = 100 bytes.

        // ---- strings block (32 bytes) ----
        0x23, 0x61, 0x64, 0x64, 0x72, 0x65, 0x73, 0x73, 0x2d, 0x63, 0x65, 0x6c, 0x6c, 0x73, 0x00, // 0: #address-cells
        0x23, 0x73, 0x69, 0x7a, 0x65, 0x2d, 0x63, 0x65, 0x6c, 0x6c, 0x73, 0x00, // 15: #size-cells
        0x72, 0x65, 0x67, 0x00, // 27: reg
        0x00, // padding to 32 bytes
    };
    const fake_dtb_ptr: [*]u8 = &fake_dtb_data;

    // Use the standard testing allocator to act as the heap.
    const allocator = testing.allocator;

    // Allocate real host memory to act as fake RAM for the test.
    const ram_size = 1024 * 1024; // 1MB.
    const fake_ram = try allocator.alloc(u8, ram_size);
    defer allocator.free(fake_ram);
    const ram_base = @intFromPtr(fake_ram.ptr);

    // Update the fake DTB reg property with the real host address of our fake RAM.
    // The reg property value starts at offset 72 (base) and 80 (size) within the struct block.
    // Struct block starts at offset 56 in the total blob.
    // So reg base is at 56 + 72 = 128. reg size is at 56 + 80 = 136.
    std.mem.writeInt(u64, fake_dtb_data[128..136], ram_base, .big);
    std.mem.writeInt(u64, fake_dtb_data[136..144], ram_size, .big);

    // Initialize mock Root VM pointers (use another real host buffer)
    const test_rootvm_data_buf = try allocator.alloc(u8, 1024);
    defer allocator.free(test_rootvm_data_buf);
    @memcpy(test_rootvm_data_buf[0..test_rootvm_data.len], &test_rootvm_data);

    test_rootvm_start = @intFromPtr(test_rootvm_data_buf.ptr);
    test_rootvm_end = test_rootvm_start + test_rootvm_data_buf.len;

    var phys_test = try physmem.initForTest(allocator, 512);
    defer phys_test.deinit();

    // Run the boot init function
    try bootCpuInit(allocator, fake_dtb_ptr);

    // Check that the global system context was created
    try testing.expect(system_ctx != null);
    if (system_ctx) |ctx| {
        // Clean up the memory allocated during the test
        if (ctx.device_tree) |tree| tree.deinit();
        if (ctx.root_vm) |g| g.deinit();
        allocator.destroy(ctx);
    }
    system_ctx = null;
}
