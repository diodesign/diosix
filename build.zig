// diosix build management
//
// Copyright (c) 2024 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const ArrayList = std.ArrayList;
const Target = std.Target;
const RISCVextensions = Target.Cpu.Feature.Set;

// define our supported systems
const SupportedSystem = struct { name: []const u8, linker_script: []const u8, top_asm_file: []const u8 };

// a supported system has:
// - a short unique descriptive name
// - a linker script allowing the hypervisor to be loaded and run by a bootloader on this system
// - a top-level assembly file that imports the assembly code needed by the hypervisor for this system
const supported_systems = [_]SupportedSystem{
    .{ .name = "qemu-virt", .linker_script = "hypervisor/hw/qemu/linker.ld", .top_asm_file = "hypervisor/hw/qemu/top.s" },
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

    // insist on building for riscv64 targets
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_arch = Target.Cpu.Arch.riscv64,
            .os_tag = Target.Os.Tag.freestanding,
            .abi = Target.Abi.none,
            .cpu_model = .{ .explicit = &Target.riscv.cpu.baseline_rv64 },
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

    // allow the user to pick a system to build for, or select a default (qemu-virt)
    const system_option = b.option(
        []const u8,
        "system",
        std.fmt.allocPrint(b.allocator, "Select the system to build for: {s} (default: qemu-virt)", .{system_names}) catch unreachable,
    ) orelse "qemu-virt";

    const selected_system = for (supported_systems) |sys| {
        if (std.mem.eql(u8, sys.name, system_option)) break sys;
    } else {
        @panic("Unsupported system selected");
    };

    const vmdiosix = b.addExecutable(.{ .name = "vmdiosix", .root_source_file = b.path("hypervisor/core/main.zig"), .target = target, .optimize = optimize, .code_model = .medium, .linkage = .static });

    // include the top-level assembly file and linker script
    vmdiosix.addAssemblyFile(b.path(selected_system.top_asm_file));
    vmdiosix.setLinkerScript(b.path(selected_system.linker_script));

    // include build-time metadata as options available to main.zig
    // this includes boot banner text, and details of the build and current version
    const metadata = b.addOptions();

    const branch = get_cmd_output(&.{ "git", "symbolic-ref", "--short", "HEAD" });
    const revision = get_cmd_output(&.{ "git", "rev-parse", "--short", "HEAD" });
    const date = get_cmd_output(&.{"date"});

    metadata.addOption([]const u8, "banner", @embedFile("boot/banner.txt"));
    metadata.addOption([]const u8, "project_version", @embedFile("VERSION"));
    metadata.addOption([]const u8, "git_branch", branch);
    metadata.addOption([]const u8, "git_revision", revision);
    metadata.addOption([]const u8, "build_date", date);
    metadata.addOption([]const u8, "cpu_arch", "riscv64");
    vmdiosix.root_module.addOptions("metadata", metadata);

    b.installArtifact(vmdiosix);
}

// run the given command and capture its output as an owned string, which is returned to the caller
// the command needs to be an array of arguments, the first being the program to execute
// all errors are fatal rather than passed up to the caller
fn get_cmd_output(args: []const []const u8) []const u8 {
    const result = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = args,
    }) catch |e| {
        std.debug.print("Failed to run command '{s}' ({})\n", .{ args, e });
        std.process.exit(1);
    };

    // get rid of whitespace at the start and end of the command's stdout
    return std.mem.trim(u8, result.stdout, " \n");
}
