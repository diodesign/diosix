// diosix build management
//
// Copyright (c) 2024 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const ArrayList = std.ArrayList;
const Target = std.Target;
const RISCVextensions = Target.Cpu.Feature.Set;

// define our supported systems
const SupportedSystem = struct { name: []const u8, linker_script: []const u8, root_asm_file: []const u8 };

const supported_systems = [_]SupportedSystem{
    .{ .name = "qemu", .linker_script = "hw/qemu/linker.ld", .root_asm_file = "hw/qemu/entry.s" },
};

pub fn build(b: *std.Build) void {
    // we're building primarily for riscv64 systems, and expect RV64IMAC as a minimum.
    // override zig's CPU extension list with our own.
    var min_cpu_features = RISCVextensions.empty;
    const i: std.Target.riscv.Feature = .i;
    const m: std.Target.riscv.Feature = .m;
    const a: std.Target.riscv.Feature = .a;
    const c: std.Target.riscv.Feature = .c;
    min_cpu_features.addFeature(@intFromEnum(i));
    min_cpu_features.addFeature(@intFromEnum(m));
    min_cpu_features.addFeature(@intFromEnum(a));
    min_cpu_features.addFeature(@intFromEnum(c));

    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_arch = Target.Cpu.Arch.riscv64,
            .os_tag = Target.Os.Tag.freestanding,
            .abi = Target.Abi.none,
            .cpu_features_sub = Target.riscv.cpu.baseline_rv64.features,
            .cpu_features_add = min_cpu_features,
        },
    });

    // allow user to control or override optimizations and release mode
    const optimize = b.standardOptimizeOption(.{});

    // create build-run-time list of supported system names
    const system_names = blk: {
        var names = ArrayList(u8).init(b.allocator);

        for (supported_systems, 0..) |sys, index| {
            names.appendSlice(sys.name) catch unreachable;
            if (index < (supported_systems.len - 1)) {
                names.appendSlice(", ") catch unreachable;
            }
        }
        break :blk names.toOwnedSlice() catch unreachable;
    };

    // allow the user to pick a system to build for, or select a default
    const system_option = b.option(
        []const u8,
        "system",
        std.fmt.allocPrint(b.allocator, "Select the system to build for: {s} (default: qemu)", .{system_names}) catch unreachable,
    ) orelse "qemu";

    const selected_system = for (supported_systems) |sys| {
        if (std.mem.eql(u8, sys.name, system_option)) break sys;
    } else {
        @panic("Unsupported system selected");
    };

    const vmdiosix = b.addExecutable(.{ .name = "vmdiosix", .root_source_file = b.path("core/main.zig"), .target = target, .optimize = optimize, .code_model = .medium, .linkage = .static });

    // include the root assembly file and linker script
    vmdiosix.addAssemblyFile(b.path(selected_system.root_asm_file));
    vmdiosix.setLinkerScript(b.path(selected_system.linker_script));

    b.installArtifact(vmdiosix);
}
