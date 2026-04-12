// diosix build management
//
// Copyright (c) 2024, 2025, 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const ArrayList = std.ArrayList;
const Target = std.Target;
const RISCVextensions = Target.Cpu.Feature.Set;

// define our supported systems
const SupportedSystem = struct { name: []const u8, linker_script: []const u8, top_asm_file: []const u8, run_cmd: []const []const u8 };

// a supported system has:
// - a short unique descriptive name
// - a linker script allowing the hypervisor to be loaded and run by a bootloader on this system
// - a top-level assembly file that imports the assembly code needed by the hypervisor for this system
// - a command to run the hypervisor in a suitable emulator
const supported_systems = [_]SupportedSystem{
    .{ .name = "qemu-virt", .linker_script = "hypervisor/hw/qemu/linker.ld", .top_asm_file = "hypervisor/hw/qemu/top.s", .run_cmd = &.{ "qemu-system-riscv64", "-nographic", "-machine", "virt", "-smp", "4", "-m", "2G", "-bios", "none", "-kernel" } },
};

pub fn build(b: *std.Build) !void {
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
        var names = try ArrayList(u8).initCapacity(b.allocator, 0);

        for (supported_systems, 0..) |sys, index| {
            names.appendSlice(b.allocator, sys.name) catch unreachable;
            if (index < (supported_systems.len - 1)) {
                names.appendSlice(", ") catch unreachable;
            }
        }
        break :blk names.toOwnedSlice(b.allocator) catch unreachable;
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

    const interface_module = b.createModule(.{
        .root_source_file = b.path("hypervisor/interface/lib.zig"),
    });

    const vmdiosix = b.addExecutable(.{ .name = "vmdiosix", .root_module = b.createModule(.{
        .root_source_file = b.path("hypervisor/core/main.zig"),
        .optimize = optimize,
        .target = target,
        .code_model = .medium,
    }), .linkage = .static });
    vmdiosix.root_module.addImport("interface", interface_module);

    // include the top-level assembly file and linker script
    vmdiosix.root_module.addAssemblyFile(b.path(selected_system.top_asm_file));
    vmdiosix.setLinkerScript(b.path(selected_system.linker_script));

    // include build-time metadata as options available to main.zig
    // this includes boot banner text, and details of the build and current version
    const metadata = b.addOptions();

    const branch = get_cmd_output(b, &.{ "git", "symbolic-ref", "--short", "HEAD" });
    const revision = get_cmd_output(b, &.{ "git", "rev-parse", "--short", "HEAD" });
    const zig_version = get_cmd_output(b, &.{ "zig", "version" });
    const build_user = get_cmd_output(b, &.{"whoami"});
    const build_hostname = get_cmd_output(b, &.{"hostname"});
    const build_date = get_cmd_output(b, &.{"date"});

    metadata.addOption([]const u8, "banner", @embedFile("boot/banner.txt"));
    metadata.addOption([]const u8, "project_version", @embedFile("VERSION"));
    metadata.addOption([]const u8, "git_branch", branch);
    metadata.addOption([]const u8, "git_revision", revision);
    metadata.addOption([]const u8, "build_date", build_date);
    metadata.addOption([]const u8, "build_user", build_user);
    metadata.addOption([]const u8, "build_hostname", build_hostname);
    metadata.addOption([]const u8, "zig_version", zig_version);
    metadata.addOption([]const u8, "cpu_arch", "riscv64");
    vmdiosix.root_module.addOptions("metadata", metadata);

    b.installArtifact(vmdiosix);

    // create a 'zig build run' command to execute the hypervisor in a suitable emulator
    const run_step = b.addSystemCommand(selected_system.run_cmd);
    run_step.step.dependOn(b.getInstallStep());

    // the last argument to qemu is the kernel file to run
    run_step.addArtifactArg(vmdiosix);

    const run_option = b.step("run", "Run the hypervisor");
    run_option.dependOn(&run_step.step);

    // run all the unit tests on the host system
    // tests use a separate module targeting native so the test runner has OS support
    const test_module = b.createModule(.{
        .root_source_file = b.path("hypervisor/core/main.zig"),
        .optimize = optimize,
        .target = b.graph.host,
    });
    test_module.addOptions("metadata", metadata);
    test_module.addImport("interface", interface_module);
    const unit_tests = b.addTest(.{
        .root_module = test_module,
        .name = "diosix-unit-tests",
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}

// run the given command and capture its output as an owned string, which is returned to the caller
// the command needs to be an array of arguments, the first being the program to execute
// all errors are fatal rather than passed up to the caller
fn get_cmd_output(b: *std.Build, args: []const []const u8) []const u8 {
    const result = b.run(args);

    // get rid of whitespace at the start and end of the command's stdout
    return std.mem.trim(u8, result, " \n");
}
