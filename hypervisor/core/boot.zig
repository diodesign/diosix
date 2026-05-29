// Diosix hypervisor early boot and cpu initialization.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const main = @import("main.zig");
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

// Root VM linker symbols.
extern const __rootvm_start: u8;
extern const __rootvm_end: u8;

// Global hypervisor state and resources
pub const SystemContext = struct {
    device_tree: ?*dt.DeviceTree,
    root_vm: ?*guest.Guest,
};

pub var system_ctx_locked = atomic.LockPayload(?*SystemContext).init(
    "Global system context",
    null,
);

// This is the core initialization logic for the boot CPU.
// It is separated from main() to allow for easier testing.
pub fn bootCpuInit(cpu_allocator: std.mem.Allocator, dtb: [*]u8) !void {
    var guest_hart_ids = std.mem.zeroes([8]usize);
    debug.printf("\n{s}\n", .{metadata.banner});
    debug.printf("Version {s} {s}/{s} {s} {s}@{s} (Zig {s} {s})\n\n", .{ metadata.project_version, metadata.git_branch, metadata.git_revision, metadata.build_date, metadata.build_user, metadata.build_hostname, metadata.zig_version, metadata.cpu_arch });

    // Set up the system context
    const system_ctx_guard = system_ctx_locked.acquire();
    defer system_ctx_guard.release();

    const system_ctx_ptr = system_ctx_guard.get();
    const ctx = try cpu_allocator.create(SystemContext);
    ctx.* = .{ .device_tree = null, .root_vm = null };

    errdefer {
        if (ctx.device_tree) |t| t.deinit();
        if (ctx.root_vm) |r| r.deinit();
        cpu_allocator.destroy(ctx);
        system_ctx_ptr.* = null; // Blank out global state
    }

    const pre_parse_dtb = try dt.DeviceTreeBlob.init(cpu_allocator, dtb);
    defer pre_parse_dtb.deinit();

    // Keep parsed tree in boot CPU core's heap.
    const device_tree = try pre_parse_dtb.parse();
    ctx.device_tree = device_tree;

    // Discover hardware peripherals from the DTB
    if (!builtin.is_test) {
        var dt_it = device_tree.iter("/", 10);
        while (dt_it.next()) |path| {
            if (device_tree.getProperty(path, "compatible")) |compat_prop| {
                if (compat_prop.asText()) |compat_text| {
                    if (std.mem.indexOf(u8, compat_text, "clint") != null or std.mem.indexOf(u8, compat_text, "sifive,clint0") != null) {
                        if (try device_tree.readAddress(path)) |addr| {
                            riscv.clint_base = addr;
                        }
                    } else if (std.mem.indexOf(u8, compat_text, "ns16550a") != null or std.mem.indexOf(u8, compat_text, "uart") != null) {
                        if (try device_tree.readAddress(path)) |addr| {
                            riscv.uart_base = addr;
                        }
                    } else if (std.mem.indexOf(u8, compat_text, "sifive,test0") != null) {
                        if (try device_tree.readAddress(path)) |addr| {
                            riscv.test_device_base = addr;
                        }
                    }
                } else |_| {}
            } else |_| {}
        }
    }

    if (riscv.clint_base) |addr| debug.printf("DTB: Discovered CLINT at 0x{x}\n", .{addr});
    if (riscv.uart_base) |addr| debug.printf("DTB: Discovered UART at 0x{x}\n", .{addr});
    if (riscv.test_device_base) |addr| debug.printf("DTB: Discovered Test/Poweroff device at 0x{x}\n", .{addr});

    // Initialize physical memory management.
    const rootvm_ram_size = if (builtin.is_test) 2 * 1024 * 1024 else 512 * 1024 * 1024;

    var rootvm_hpa_base: usize = 0;
    var rootvm_region: physmem.Region = undefined;

    if (!builtin.is_test) {
        try physmem.discoverRegions(device_tree);
        rootvm_region = try physmem.findContiguousRegion(rootvm_ram_size);
        rootvm_hpa_base = rootvm_region.base;
    } else {
        // In tests, allocate 2MB (order 9) for Root VM.
        rootvm_hpa_base = try physmem.allocPageSelection(9);
        rootvm_region = .{ .base = rootvm_hpa_base, .size = rootvm_ram_size };
    }

    try riscv.verifyHExtension();

    if (!builtin.is_test) {
        try physmem.init(device_tree, rootvm_region);
    }

    // Initialize the global scheduler.
    scheduler.init();

    const rootvm_elf_base = if (builtin.is_test) test_rootvm_start else @intFromPtr(&__rootvm_start);
    const rootvm_elf_size = if (builtin.is_test) test_rootvm_end - rootvm_elf_base else @intFromPtr(&__rootvm_end) - rootvm_elf_base;

    // Create the trusted Root VM.
    // Guest RAM starts at 0x80000000 (standard for RISC-V Linux).
    const root_vm_gpa_base = 0x80000000;
    const root_vm = try guest.createGuest(cpu_allocator, true, true, null, root_vm_gpa_base, rootvm_hpa_base, rootvm_ram_size);
    ctx.root_vm = root_vm;

    // Zero out the entire guest RAM reservation to ensure a clean slate.
    @memset(@as([*]u8, @ptrFromInt(rootvm_hpa_base))[0..rootvm_ram_size], 0);

    // Load the Root VM ELF and get its entry point.
    // ELF segments are mapped as RWX inside Loader.load().
    const entry_point = try loader.Loader.load(root_vm, @as([*]const u8, @ptrFromInt(rootvm_elf_base))[0..rootvm_elf_size]);

    // Generate a guest DTB from the host device tree.
    // Tailor it for the Root VM: 512MB RAM and 2 virtual CPUs.
    const guest_memory_node = try std.fmt.allocPrint(cpu_allocator, "/memory@{x}", .{root_vm_gpa_base});
    defer cpu_allocator.free(guest_memory_node);

    // Update memory node for the guest
    try device_tree.editProperty(guest_memory_node, "reg", try dt.DeviceTreeProperty.fromMultiU64(cpu_allocator, &.{ root_vm_gpa_base, rootvm_ram_size }));
    try device_tree.editProperty(guest_memory_node, "device_type", try dt.DeviceTreeProperty.fromText(cpu_allocator, "memory"));

    const cpu_count = 1;
    debug.printf("Provisioning Root VM with {} virtual CPUs\n", .{cpu_count});

    // Inject boot arguments and console path into the guest DTB to ensure it uses the SBI console (hvc0)
    device_tree.editProperty("/chosen", "bootargs", try dt.DeviceTreeProperty.fromText(cpu_allocator, "console=hvc0 earlycon=sbi riscv_aia=off")) catch |err| {
        debug.printf("Warning: Failed to inject bootargs into guest DTB: {s}\n", .{@errorName(err)});
    };
    device_tree.editProperty("/chosen", "stdout-path", try dt.DeviceTreeProperty.fromText(cpu_allocator, "serial0:115200n8")) catch |err| {
        debug.printf("Warning: Failed to inject stdout-path into guest DTB: {s}\n", .{@errorName(err)});
    };

    // Clean up host-specific reserved memory nodes and entries for the guest DTB.
    // The guest has its own private RAM range (GPA 0x80000000) and does not need
    // or overlap with host-specific reservations.
    device_tree.reserved_count = 0;
    while (true) {
        var res_it = device_tree.iter("/reserved-memory", 10);
        if (res_it.next()) |path| {
            device_tree.deleteNode(path);
        } else break;
    }

    // Clean up AIA interrupt controller nodes (aplic and imsic) to force
    // the guest kernel to fall back to PLIC, preventing tight loops on siselect/sireg.
    while (true) {
        var aia_it = device_tree.iter("/", 10);
        var found_aia: ?[]const u8 = null;
        while (aia_it.next()) |path| {
            if (std.mem.indexOf(u8, path, "aplic") != null or std.mem.indexOf(u8, path, "imsic") != null) {
                found_aia = path;
                break;
            }
        }
        if (found_aia) |path| {
            device_tree.deleteNode(path);
        } else break;
    }

    var disabled_phandles = std.ArrayList(u32).empty;
    defer disabled_phandles.deinit(cpu_allocator);

    // Keep only virtual CPU 0 active in the guest DTB by marking any extra `/cpus/cpu@` node as disabled.
    var cpu_it = device_tree.iter("/cpus/cpu@", 10);
    var enabled_cpu_index: usize = 0;
    while (cpu_it.next()) |path| {
        // Strip Sstc for all CPU nodes so the guest does not use the Sstc timer extension
        var slash_count: usize = 0;
        for (path) |c| {
            if (c == '/') slash_count += 1;
        }
        if (slash_count == 2) {
            // Let's strip "sstc" from "riscv,isa" property of this CPU node.
            if (device_tree.getProperty(path, "riscv,isa")) |isa_prop| {
                if (isa_prop.asText()) |isa_text| {
                    var new_isa = std.ArrayList(u8).empty;
                    defer new_isa.deinit(cpu_allocator);

                    var i: usize = 0;
                    while (i < isa_text.len) {
                        if (i + 5 <= isa_text.len and std.mem.eql(u8, isa_text[i .. i + 5], "_sstc")) {
                            i += 5;
                        } else if (i + 4 <= isa_text.len and std.mem.eql(u8, isa_text[i .. i + 4], "sstc")) {
                            i += 4;
                        } else {
                            try new_isa.append(cpu_allocator, isa_text[i]);
                            i += 1;
                        }
                    }
                    try device_tree.editProperty(path, "riscv,isa", try dt.DeviceTreeProperty.fromText(cpu_allocator, new_isa.items));
                } else |_| {}
            } else |_| {}

            // Let's strip "sstc" from "riscv,isa-extensions" property of this CPU node if it exists.
            if (device_tree.getProperty(path, "riscv,isa-extensions")) |ext_prop| {
                if (ext_prop.asMultiText(cpu_allocator)) |extensions| {
                    defer cpu_allocator.free(extensions);
                    var new_extensions = std.ArrayList(u8).empty;
                    defer new_extensions.deinit(cpu_allocator);
                    var changed = false;
                    for (extensions) |ext_str| {
                        if (std.mem.eql(u8, ext_str, "sstc")) {
                            changed = true;
                        } else {
                            try new_extensions.appendSlice(cpu_allocator, ext_str);
                            try new_extensions.append(cpu_allocator, 0);
                        }
                    }
                    if (changed) {
                        try device_tree.editProperty(path, "riscv,isa-extensions", try dt.DeviceTreeProperty.fromBytes(cpu_allocator, new_extensions.items));
                    }
                } else |_| {}
            } else |_| {}
        }

        if (slash_count == 2) {
            if (enabled_cpu_index < cpu_count) {
                try device_tree.editProperty(path, "status", try dt.DeviceTreeProperty.fromText(cpu_allocator, "okay"));

                // Read its original "reg" property as the physical hart ID
                var reg_val: usize = enabled_cpu_index; // fallback
                if (device_tree.getProperty(path, "reg")) |reg_prop| {
                    if (reg_prop.data) |reg_data| {
                        if (reg_data.len == 8) {
                            reg_val = (@as(usize, reg_data[0]) << 56) | (@as(usize, reg_data[1]) << 48) |
                                (@as(usize, reg_data[2]) << 40) | (@as(usize, reg_data[3]) << 32) |
                                (@as(usize, reg_data[4]) << 24) | (@as(usize, reg_data[5]) << 16) |
                                (@as(usize, reg_data[6]) << 8) | reg_data[7];
                        } else if (reg_data.len == 4) {
                            reg_val = (@as(usize, reg_data[0]) << 24) | (@as(usize, reg_data[1]) << 16) |
                                (@as(usize, reg_data[2]) << 8) | reg_data[3];
                        }
                    }
                } else |_| {}

                if (enabled_cpu_index < guest_hart_ids.len) {
                    guest_hart_ids[enabled_cpu_index] = reg_val;
                }

                enabled_cpu_index += 1;
            } else {
                try device_tree.editProperty(path, "status", try dt.DeviceTreeProperty.fromText(cpu_allocator, "disabled"));

                // Add the sub-node interrupt-controller's phandle to the disabled list
                const ic_path = try std.fmt.allocPrint(cpu_allocator, "{s}/interrupt-controller", .{path});
                defer cpu_allocator.free(ic_path);
                if (device_tree.getProperty(ic_path, "phandle")) |prop| {
                    if (prop.data) |data| {
                        if (data.len >= 4) {
                            const phandle = (@as(u32, data[0]) << 24) | (@as(u32, data[1]) << 16) | (@as(u32, data[2]) << 8) | data[3];
                            try disabled_phandles.append(cpu_allocator, phandle);
                        }
                    }
                } else |_| {}
            }
        }
    }

    // Filter PLIC interrupts-extended to remove references to disabled CPUs
    var plic_it = device_tree.iter("/", 10);
    while (plic_it.next()) |path| {
        if (std.mem.indexOf(u8, path, "plic") != null or std.mem.indexOf(u8, path, "interrupt-controller") != null) {
            if (device_tree.getProperty(path, "interrupts-extended")) |prop| {
                if (prop.data) |data| {
                    var new_data = std.ArrayList(u8).empty;
                    defer new_data.deinit(cpu_allocator);

                    var offset: usize = 0;
                    while (offset + 7 < data.len) : (offset += 8) {
                        const phandle = (@as(u32, data[offset]) << 24) | (@as(u32, data[offset + 1]) << 16) | (@as(u32, data[offset + 2]) << 8) | data[offset + 3];

                        // Check if this phandle is in the disabled list
                        var is_disabled = false;
                        for (disabled_phandles.items) |dp| {
                            if (dp == phandle) {
                                is_disabled = true;
                                break;
                            }
                        }

                        if (!is_disabled) {
                            try new_data.appendSlice(cpu_allocator, data[offset .. offset + 8]);
                        }
                    }

                    // Replace the property
                    try device_tree.editProperty(path, "interrupts-extended", try dt.DeviceTreeProperty.fromBytes(cpu_allocator, new_data.items));
                }
            } else |_| {}
        }
    }

    const guest_dtb = try device_tree.toBlob();
    defer cpu_allocator.free(guest_dtb);

    // Provide a devicetree for the guest.
    // Place it 1MB from the end of the guest's physical RAM reservation.
    const guest_dtb_gpa = root_vm_gpa_base + rootvm_ram_size - 1024 * 1024;
    const guest_dtb_hpa = try root_vm.space.translateGPA(guest_dtb_gpa);
    @memcpy(@as([*]u8, @ptrFromInt(guest_dtb_hpa))[0..guest_dtb.len], guest_dtb);

    // Map the DTB area as RWX explicitly. The rest of the 512MB RAM will be demand-paged.
    try root_vm.space.map(guest_dtb_gpa, guest_dtb_hpa, guest_dtb.len, sv39x4.PTEFlags.read | sv39x4.PTEFlags.write | sv39x4.PTEFlags.execute | sv39x4.PTEFlags.valid | sv39x4.PTEFlags.accessed | sv39x4.PTEFlags.dirty | sv39x4.PTEFlags.user);

    debug.printf("Using Root VM image at 0x{x} ({} bytes), entry at 0x{x}\n", .{ rootvm_elf_base, rootvm_elf_size, entry_point });

    // Create virtual cores for the Root VM matching host count.
    // The loader returns the entry point as a GPA, so no masking is needed.
    for (0..cpu_count) |i| {
        // Core 0 starts executing immediately and is enrolled in the scheduler.
        // Other cores wait for HSM HART_START, so they are not queued here.
        const vcore_id = guest_hart_ids[i];
        const vc = try root_vm.addVcore(vcore_id, entry_point, guest_dtb_gpa, .high, null);
        if (i == 0) {
            vc.state = .ready;
            scheduler.queue(vc);
        }
    }

    main.global_root_vm = root_vm;
    system_ctx_ptr.* = ctx;
}

// ----------------------- testing ---------------------

// Mock Root VM symbols for tests.
const test_rootvm_data = if (builtin.is_test) blk: {
    var data: [64]u8 = std.mem.zeroes([64]u8);
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
    data[elf_spec.EHDR.PHOFF] = 64; // Program header offset
    data[elf_spec.EHDR.PHENTSIZE] = 56; // Program header size
    data[elf_spec.EHDR.PHNUM] = 0; // Number of program headers
    break :blk data;
} else {};
pub var test_rootvm_start: usize = 0;
pub var test_rootvm_end: usize = 0;

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

    riscv.initMockHardware();

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

    var phys_test = try physmem.initForTest(allocator, 1024);
    defer phys_test.deinit();

    // Run the boot init function
    try bootCpuInit(allocator, fake_dtb_ptr);

    // Check that the global system context was created
    const system_ctx_guard = system_ctx_locked.acquire();
    defer system_ctx_guard.release();
    const system_ctx_ptr = system_ctx_guard.get();

    try testing.expect(system_ctx_ptr.* != null);
    if (system_ctx_ptr.*) |ctx| {
        // Clean up the memory allocated during the test
        if (ctx.device_tree) |tree| tree.deinit();
        if (ctx.root_vm) |g| g.deinit();
        allocator.destroy(ctx);
    }
    system_ctx_ptr.* = null;
}
