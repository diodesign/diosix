// Diosix hypervisor early boot and cpu initialization.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const main = @import("main.zig");
const xint = @import("arch/riscv64/xint.zig");
const debug = @import("debug.zig");
const riscv = @import("arch/riscv64/riscv.zig");
const alloc = @import("alloc.zig");
const atomic = @import("atomic.zig");
const dt = @import("dt.zig");
const physmem = @import("physmem.zig");
const scheduler = @import("scheduler.zig");
const guest = @import("guest.zig");
const vcore = @import("vcore.zig");
const loader = @import("loader.zig");
const pcore = @import("pcore.zig");
const sv39x4 = @import("arch/riscv64/sv39x4.zig");
const elf_spec = @import("interface").elf;
const emulation = @import("emulation.zig");

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
    debug.printf("\n{s}\n", .{banner});
    debug.printf("Version {s} {s}/{s} {s} {s}@{s} (Zig {s} {s})\n\n", .{ project_version, git_branch, git_revision, build_date, build_user, build_hostname, zig_version, cpu_arch });

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
                    } else if (std.mem.indexOf(u8, compat_text, "plic") != null or std.mem.indexOf(u8, compat_text, "sifive,plic") != null) {
                        if (try device_tree.readAddress(path)) |addr| {
                            riscv.plic_base = addr;
                        }
                    }
                } else |_| {}
            } else |_| {}
        }
    }

    if (riscv.clint_base) |addr| debug.printf("Discovered CLINT at HPA 0x{x}\n", .{addr});
    if (riscv.uart_base) |addr| debug.printf("Discovered UART at HPA 0x{x}\n", .{addr});
    if (riscv.test_device_base) |addr| debug.printf("Discovered Test/Poweroff device at HPA 0x{x}\n", .{addr});
    if (riscv.plic_base) |addr| debug.printf("Discovered PLIC at HPA 0x{x}\n", .{addr});

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

    try riscv.auditCpuFeatures();

    // Initialize host dynamic device drivers
    const drivers = @import("drivers.zig");
    drivers.init();

    if (!builtin.is_test) {
        try physmem.init(device_tree, rootvm_region);
    }

    // Initialize the global scheduler.
    scheduler.init();

    const rootvm_elf_base = if (builtin.is_test) test_rootvm_start else @intFromPtr(&__rootvm_start);
    const rootvm_elf_size = if (builtin.is_test) test_rootvm_end - rootvm_elf_base else @intFromPtr(&__rootvm_end) - rootvm_elf_base;

    // Create the trusted Root VM.
    // Guest RAM starts at 0x80000000 (standard for RISC-V Linux) if H-extension is active.
    // For PMP fallback mode, guest RAM must start at the actual host physical address (HPA).
    const root_vm_gpa_base = if (riscv.hasHExtension()) 0x80000000 else rootvm_hpa_base;
    const rootvm_elf = @as([*]const u8, @ptrFromInt(rootvm_elf_base))[0..rootvm_elf_size];
    const guest_arch = try loader.Loader.detectArch(rootvm_elf);
    debug.printf("Detected guest VM target architecture: {s}\n", .{@tagName(guest_arch)});
    const root_vm = try guest.createGuest(cpu_allocator, true, true, null, root_vm_gpa_base, rootvm_hpa_base, rootvm_ram_size, guest_arch);
    ctx.root_vm = root_vm;

    // Zero out the entire guest RAM reservation to ensure a clean slate.
    @memset(@as([*]u8, @ptrFromInt(rootvm_hpa_base))[0..rootvm_ram_size], 0);

    // Load the Root VM ELF and get its entry point.
    // ELF segments are mapped as RWX inside Loader.load().
    const entry_point = try loader.Loader.load(root_vm, @as([*]const u8, @ptrFromInt(rootvm_elf_base))[0..rootvm_elf_size]);

    // ---- DTB Generation ----
    // For aarch64 guests, we generate a DTB from scratch describing the virtual
    // machine's resources. For RISC-V guests, we modify the host DTB.
    const cpu_count: usize = 4;
    debug.printf("Provisioning Root VM with {} virtual CPUs\n", .{cpu_count});

    var guest_dtb: []u8 = undefined;
    var guest_dtb_owned_tree: ?*dt.DeviceTree = null;
    defer {
        if (guest_dtb_owned_tree) |tree| tree.deinit();
        cpu_allocator.free(guest_dtb);
    }

    if (guest_arch == .aarch64) {
        // Build a minimal DTB from scratch for the aarch64 guest.
        const arm_dt = try buildAarch64Dtb(cpu_allocator, root_vm_gpa_base, rootvm_ram_size, cpu_count);
        guest_dtb_owned_tree = arm_dt;
        guest_dtb = try arm_dt.toBlob();
    } else {
        // RISC-V path: modify the host device tree for the guest.
        // First, delete any existing /memory@* nodes from the host DTB.
        while (true) {
            var mem_it = device_tree.iter("/", 1);
            var found_mem: ?[]const u8 = null;
            while (mem_it.next()) |path| {
                if (std.mem.startsWith(u8, path, "/memory@")) {
                    found_mem = path;
                    break;
                }
            }
            if (found_mem) |path| {
                device_tree.deleteNode(path);
            } else break;
        }

        const guest_memory_node = try std.fmt.allocPrint(cpu_allocator, "/memory@{x}", .{root_vm_gpa_base});
        defer cpu_allocator.free(guest_memory_node);

        // Add the guest's private memory node

        try device_tree.editProperty(guest_memory_node, "reg", try dt.DeviceTreeProperty.fromMultiU64(cpu_allocator, &.{ root_vm_gpa_base, rootvm_ram_size }));
        try device_tree.editProperty(guest_memory_node, "device_type", try dt.DeviceTreeProperty.fromText(cpu_allocator, "memory"));

        // Inject boot arguments into the guest DTB.
        // Use hvc0 as the primary console and SBI for early boot output.
        // maxcpus limits the number of CPUs the guest will bring online.
        const bootargs = try std.fmt.allocPrint(cpu_allocator, "console=hvc0 earlycon=sbi maxcpus={} unaligned_scalar_speed=fast", .{cpu_count});
        defer cpu_allocator.free(bootargs);
        device_tree.editProperty("/chosen", "bootargs", try dt.DeviceTreeProperty.fromText(cpu_allocator, bootargs)) catch |err| {
            debug.printf("Warning: Failed to inject bootargs into guest DTB: {s}\n", .{@errorName(err)});
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
            var slash_count: usize = 0;
            for (path) |c| {
                if (c == '/') slash_count += 1;
            }
            if (slash_count == 2) {
                if (guest_arch == .riscv32) {
                    // Emulated guest: replace riscv,isa with only the extensions
                    // that Unicorn's QEMU fork supports (rv32imafdc). The host DTB
                    // advertises many extensions (Zbb, Zba, Zbs, Zfa, Zicbom, etc.)
                    // that Unicorn cannot execute. The kernel will use software
                    // fallbacks for anything not in this ISA string.
                    try device_tree.editProperty(path, "riscv,isa", try dt.DeviceTreeProperty.fromText(cpu_allocator, "rv32imafdc"));

                    // Set the new-style ISA base property. Linux 7.0 uses
                    // riscv,isa-base + riscv,isa-extensions as the primary ISA
                    // discovery mechanism. Without riscv,isa-base the kernel
                    // may reject the CPU entirely.
                    try device_tree.editProperty(path, "riscv,isa-base", try dt.DeviceTreeProperty.fromText(cpu_allocator, "rv32i"));

                    // Set mmu-type to sv32 for 32-bit guests. The host DTB has
                    // sv48 or sv39 (64-bit MMU types) which makes the rv32 kernel
                    // reject the CPU as "incompatible".
                    try device_tree.editProperty(path, "mmu-type", try dt.DeviceTreeProperty.fromText(cpu_allocator, "riscv,sv32"));

                    // Set riscv,isa-extensions to only supported extensions.
                    // Always set this (not conditional on existing) since the
                    // kernel may rely on it as the primary ISA source.
                    {
                        var minimal_exts = std.ArrayList(u8).empty;
                        defer minimal_exts.deinit(cpu_allocator);
                        for ([_][]const u8{ "i", "m", "a", "f", "d", "c", "zicsr", "zifencei" }) |ext| {
                            try minimal_exts.appendSlice(cpu_allocator, ext);
                            try minimal_exts.append(cpu_allocator, 0);
                        }
                        try device_tree.editProperty(path, "riscv,isa-extensions", try dt.DeviceTreeProperty.fromBytes(cpu_allocator, minimal_exts.items));
                    }
                }
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

        // Delete extra CPU nodes beyond cpu_count from the DTB entirely.
        // The kernel's setup_smp can BUG even on disabled CPU nodes.
        // We must delete all descendants too (e.g., interrupt-controller),
        // otherwise the serializer recreates empty parent nodes.
        // Delete one at a time (restart iteration after each delete).
        while (true) {
            var del_it = device_tree.iter("/cpus/cpu@", 10);
            var del_index: usize = 0;
            var found_to_delete: ?[]const u8 = null;
            var delete_prefix: ?[]const u8 = null;
            while (del_it.next()) |path| {
                // Check if this path is a child of a CPU we already want to delete.
                if (delete_prefix) |prefix| {
                    if (std.mem.startsWith(u8, path, prefix)) {
                        found_to_delete = path;
                        break;
                    }
                    // Past the prefix's children, we found a new CPU node.
                    // Delete the prefix itself first.
                    found_to_delete = null;
                    delete_prefix = null;
                }

                var slash_cnt: usize = 0;
                for (path) |c| {
                    if (c == '/') slash_cnt += 1;
                }
                if (slash_cnt == 2) {
                    if (del_index >= cpu_count) {
                        // Mark this CPU and all its children for deletion.
                        // First delete children, then the node itself.
                        delete_prefix = path;
                        found_to_delete = path;
                        // Don't break — look for children first.
                    } else {
                        del_index += 1;
                    }
                }
            }
            if (found_to_delete) |path| {
                device_tree.deleteNode(path);
            } else break;
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

        guest_dtb = try device_tree.toBlob();
    }

    // Provide a devicetree for the guest.
    // Place it 1MB from the end of the guest's physical RAM reservation.
    const guest_dtb_gpa = root_vm_gpa_base + rootvm_ram_size - 1024 * 1024;
    const guest_dtb_hpa = try root_vm.space.translateGPA(guest_dtb_gpa);
    @memcpy(@as([*]u8, @ptrFromInt(guest_dtb_hpa))[0..guest_dtb.len], guest_dtb);

    // Map the DTB area as RWX explicitly. The rest of the 512MB RAM will be demand-paged.
    try root_vm.space.map(guest_dtb_gpa, guest_dtb_hpa, guest_dtb.len, sv39x4.PTEFlags.read | sv39x4.PTEFlags.write | sv39x4.PTEFlags.execute | sv39x4.PTEFlags.valid | sv39x4.PTEFlags.accessed | sv39x4.PTEFlags.dirty | sv39x4.PTEFlags.user);

    debug.printf("Using Root VM image at HPA 0x{x} ({} bytes), entry at GPA 0x{x}\n", .{ rootvm_elf_base, rootvm_elf_size, entry_point });

    // Create virtual cores for the Root VM matching host count.
    // The loader returns the entry point as a GPA, so no masking is needed.
    const is_emulated = (guest_arch != .riscv64);
    const hypervisor_vcore_count = if (is_emulated) 1 else cpu_count;

    for (0..hypervisor_vcore_count) |i| {
        // Core 0 starts executing immediately and is enrolled in the scheduler.
        // Other cores wait for HSM HART_START, so they are not queued here.
        const vcore_id = if (guest_arch == .aarch64) i else guest_hart_ids[i];
        const vc = try root_vm.addVcore(vcore_id, entry_point, guest_dtb_gpa, .high, null);
        
        if (is_emulated) {
            vc.exec_path.emulated.sub_vcore_count = cpu_count;
            vc.exec_path.emulated.sub_vcores[0].start_pc = entry_point;
            vc.exec_path.emulated.sub_vcores[0].start_a0 = vcore_id;
            vc.exec_path.emulated.sub_vcores[0].start_a1 = guest_dtb_gpa;
            vc.exec_path.emulated.sub_vcores[0].state = .ready;
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

/// Build a minimal AArch64 device tree from scratch.
///
/// Describes the virtual machine's resources: CPU cores, RAM, PL011 UART,
/// ARM generic timer, PSCI interface, and GICv2 interrupt controller.
///
/// The DTB follows the standard QEMU virt machine layout:
///   - GPA base for RAM: `ram_base` (typically 0x80000000)
///   - PL011 UART at 0x09000000
///   - GICv2 distributor at 0x08000000, CPU interface at 0x08010000
fn buildAarch64Dtb(allocator: std.mem.Allocator, ram_base: usize, ram_size: usize, cpu_count: usize) !*dt.DeviceTree {
    const arm_dt = try dt.DeviceTree.init(allocator);
    errdefer arm_dt.deinit();

    // Root node properties.
    try arm_dt.editProperty("/", "compatible", try dt.DeviceTreeProperty.fromText(allocator, "linux,dummy-virt"));
    try arm_dt.editProperty("/", "#address-cells", try dt.DeviceTreeProperty.fromU32(allocator, 2));
    try arm_dt.editProperty("/", "#size-cells", try dt.DeviceTreeProperty.fromU32(allocator, 2));
    try arm_dt.editProperty("/", "model", try dt.DeviceTreeProperty.fromText(allocator, "diosix,virt"));
    try arm_dt.editProperty("/", "interrupt-parent", try dt.DeviceTreeProperty.fromU32(allocator, 1)); // phandle 1 = GIC

    // /chosen — boot arguments.
    try arm_dt.editProperty("/chosen", "bootargs", try dt.DeviceTreeProperty.fromText(
        allocator,
        "earlycon=pl011,mmio32,0x09000000 console=ttyAMA0 nokaslr norandmaps panic=30",
    ));
    try arm_dt.editProperty("/chosen", "stdout-path", try dt.DeviceTreeProperty.fromText(allocator, "/pl011@9000000"));

    // /memory — guest RAM.
    const mem_node = try std.fmt.allocPrint(allocator, "/memory@{x}", .{ram_base});
    defer allocator.free(mem_node);
    try arm_dt.editProperty(mem_node, "device_type", try dt.DeviceTreeProperty.fromText(allocator, "memory"));
    try arm_dt.editProperty(mem_node, "reg", try dt.DeviceTreeProperty.fromMultiU64(allocator, &.{ ram_base, ram_size }));

    // /cpus
    try arm_dt.editProperty("/cpus", "#address-cells", try dt.DeviceTreeProperty.fromU32(allocator, 1));
    try arm_dt.editProperty("/cpus", "#size-cells", try dt.DeviceTreeProperty.fromU32(allocator, 0));

    for (0..cpu_count) |i| {
        const cpu_node = try std.fmt.allocPrint(allocator, "/cpus/cpu@{}", .{i});
        defer allocator.free(cpu_node);
        try arm_dt.editProperty(cpu_node, "device_type", try dt.DeviceTreeProperty.fromText(allocator, "cpu"));
        try arm_dt.editProperty(cpu_node, "compatible", try dt.DeviceTreeProperty.fromText(allocator, "arm,cortex-a53"));
        try arm_dt.editProperty(cpu_node, "reg", try dt.DeviceTreeProperty.fromU32(allocator, @intCast(i)));
        try arm_dt.editProperty(cpu_node, "enable-method", try dt.DeviceTreeProperty.fromText(allocator, "psci"));
    }

    // /psci — Power State Coordination Interface.
    try arm_dt.editProperty("/psci", "compatible", try dt.DeviceTreeProperty.fromText(allocator, "arm,psci-1.0"));
    try arm_dt.editProperty("/psci", "method", try dt.DeviceTreeProperty.fromText(allocator, "hvc"));

    // /timer — ARM generic timer.
    // interrupts: GIC_PPI (type=1) for secure phys (13), non-secure phys (14),
    // virtual (11), hypervisor (10). Flags: 0x304 = level-triggered, active-low.
    // Each interrupt is a triplet: <type number flags>
    try arm_dt.editProperty("/timer", "compatible", try dt.DeviceTreeProperty.fromText(allocator, "arm,armv8-timer"));
    try arm_dt.editProperty("/timer", "interrupts", try dt.DeviceTreeProperty.fromMultiU32(allocator, &.{
        1, 13, 0x304, // Secure physical timer PPI
        1, 14, 0x304, // Non-secure physical timer PPI
        1, 11, 0x304, // Virtual timer PPI
        1, 10, 0x304, // Hypervisor timer PPI
    }));
    try arm_dt.editProperty("/timer", "always-on", dt.DeviceTreeProperty.empty);

    // /pl011@9000000 — UART.
    try arm_dt.editProperty("/pl011@9000000", "compatible", try dt.DeviceTreeProperty.fromText(allocator, "arm,pl011"));
    try arm_dt.editProperty("/pl011@9000000", "reg", try dt.DeviceTreeProperty.fromMultiU64(allocator, &.{ 0x09000000, 0x1000 }));
    // SPI 1 (type=0, number=1) for UART interrupt.
    try arm_dt.editProperty("/pl011@9000000", "interrupts", try dt.DeviceTreeProperty.fromMultiU32(allocator, &.{ 0, 1, 4 }));

    // /intc@8000000 — GICv2 interrupt controller.
    try arm_dt.editProperty("/intc@8000000", "compatible", try dt.DeviceTreeProperty.fromText(allocator, "arm,cortex-a15-gic"));
    try arm_dt.editProperty("/intc@8000000", "#interrupt-cells", try dt.DeviceTreeProperty.fromU32(allocator, 3));
    try arm_dt.editProperty("/intc@8000000", "interrupt-controller", dt.DeviceTreeProperty.empty);
    // reg: distributor (0x08000000, 0x10000), CPU interface (0x08010000, 0x10000)
    try arm_dt.editProperty("/intc@8000000", "reg", try dt.DeviceTreeProperty.fromMultiU64(allocator, &.{
        0x08000000, 0x10000, // GIC distributor
        0x08010000, 0x10000, // GIC CPU interface
    }));
    try arm_dt.editProperty("/intc@8000000", "phandle", try dt.DeviceTreeProperty.fromU32(allocator, 1));
    try arm_dt.editProperty("/intc@8000000", "#address-cells", try dt.DeviceTreeProperty.fromU32(allocator, 0));

    return arm_dt;
}

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
