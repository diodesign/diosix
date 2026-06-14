// diosix build management
//
// Don't invoke this file directly. Instead use the wrapper `./scripts/build.sh`.
// This wrapper ensures that all necessary build-time metadata is freshly captured
// and passed to the build automatically.
//
// Copyright (c) 2024, 2025, 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const ArrayList = std.ArrayList;
const Target = std.Target;
const RISCVextensions = Target.Cpu.Feature.Set;
const yaml = @import("scripts/yaml_parser.zig");

pub fn build(b: *std.Build) !void {
    // Run self-tests for the YAML parser before using it
    yaml.selfCheck() catch |err| {
        std.debug.print("YAML parser self-check failed: {any}\n", .{err});
        return err;
    };

    const git_branch = b.option([]const u8, "git_branch", "Current git branch") orelse "unknown branch";
    const git_revision = b.option([]const u8, "git_revision", "Current git revision") orelse "unknown revision";
    const zig_version_opt = b.option([]const u8, "zig_version", "Current zig version") orelse "unknown zig version";
    const build_user = b.option([]const u8, "build_user", "Current build user") orelse "unknown build user";
    const build_hostname = b.option([]const u8, "build_hostname", "Current build hostname") orelse "unknown build host";
    const build_date = b.option([]const u8, "build_date", "Current build date") orelse "unknown build date";

    // Dynamic hardware port discovery from hypervisor/hw/ports/
    const ports_dir_path = "hypervisor/hw/ports";
    var ports_dir = b.root.root_dir.handle.openDir(b.graph.io, ports_dir_path, .{ .iterate = true }) catch |err| {
        std.debug.print("Failed to open hardware ports directory '{s}': {any}\n", .{ ports_dir_path, err });
        return err;
    };
    defer ports_dir.close(b.graph.io);

    var system_list = ArrayList([]const u8).empty;
    defer {
        for (system_list.items) |sys| b.allocator.free(sys);
        system_list.deinit(b.allocator);
    }

    var ports_iter = ports_dir.iterate();
    while (try ports_iter.next(b.graph.io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".yaml") and !std.mem.eql(u8, entry.name, "default.yaml")) {
            const sys_name = entry.name[0 .. entry.name.len - 5]; // strip ".yaml"
            try system_list.append(b.allocator, try b.allocator.dupe(u8, sys_name));
        }
    }

    // Build-run-time list of supported system names for option help display
    var names_buf = ArrayList(u8).empty;
    defer names_buf.deinit(b.allocator);
    for (system_list.items, 0..) |sys_name, idx| {
        try names_buf.appendSlice(b.allocator, sys_name);
        if (idx < (system_list.items.len - 1)) {
            try names_buf.appendSlice(b.allocator, ", ");
        }
    }
    const system_names = try names_buf.toOwnedSlice(b.allocator);
    defer b.allocator.free(system_names);

    // Parse the default system from hypervisor/hw/ports/default.yaml
    const default_yaml_path = try std.fs.path.join(b.allocator, &.{ ports_dir_path, "default.yaml" });
    defer b.allocator.free(default_yaml_path);
    const default_content = b.root.root_dir.handle.readFileAlloc(b.graph.io, default_yaml_path, b.allocator, std.Io.Limit.limited(1024 * 1024)) catch |err| {
        std.debug.print("Failed to read default system file '{s}': {any}\n", .{ default_yaml_path, err });
        return err;
    };
    defer b.allocator.free(default_content);
    const default_system = try yaml.parseDefault(b.allocator, default_content);
    defer b.allocator.free(default_system);

    // Allow user to pick a target hardware system to build for, defaulting to value in default.yaml
    const system_option = b.option(
        []const u8,
        "system",
        std.fmt.allocPrint(b.allocator, "Select the system to build for: {s} (default: {s})", .{ system_names, default_system }) catch unreachable,
    ) orelse default_system;

    // Load and parse selected system YAML configuration early so we can inspect its legacy_cpu configuration
    const selected_yaml_filename = try std.fmt.allocPrint(b.allocator, "{s}.yaml", .{system_option});
    defer b.allocator.free(selected_yaml_filename);
    const selected_yaml_path = try std.fs.path.join(b.allocator, &.{ ports_dir_path, selected_yaml_filename });
    defer b.allocator.free(selected_yaml_path);
    const selected_yaml_content = b.root.root_dir.handle.readFileAlloc(b.graph.io, selected_yaml_path, b.allocator, std.Io.Limit.limited(1024 * 1024)) catch |err| {
        std.debug.print("Failed to read system configuration file '{s}': {any}\n", .{ selected_yaml_path, err });
        return err;
    };
    defer b.allocator.free(selected_yaml_content);

    const port_config = yaml.parse(b.allocator, selected_yaml_content) catch |err| {
        std.debug.print("Failed to parse system configuration file '{s}': {any}\n", .{ selected_yaml_path, err });
        return err;
    };
    defer port_config.deinit(b.allocator);

    // Allow user to override the CPU model/extensions passed to QEMU
    const qemu_cpu_opt = b.option([]const u8, "qemu-cpu", "Override the CPU model/extensions passed to QEMU");

    // Allow user to compile out Sstc and Smstateen support for legacy CPUs (e.g. QEMU 6.2)
    // If not specified, default to the setting parsed from the target hardware YAML configuration.
    const legacy_cpu_opt = b.option(bool, "legacy-cpu", "Compile out Sstc and Smstateen support");
    const legacy_cpu = legacy_cpu_opt orelse port_config.legacy_cpu;

    // Generate config.s dynamically
    const config_s_content = try std.fmt.allocPrint(b.allocator,
        \\# Dynamically generated by build.zig. DO NOT EDIT.
        \\.equ LEGACY_CPU, {d}
        \\
    , .{@intFromBool(legacy_cpu)});

    // we're building primarily for riscv64 systems, and expect RV64IMAC as a minimum.
    // override zig's CPU extension list with our own.
    var min_cpu_features = RISCVextensions.empty;
    const i: std.Target.riscv.Feature = .i;
    const m: std.Target.riscv.Feature = .m;
    const a: std.Target.riscv.Feature = .a;
    const c: std.Target.riscv.Feature = .c;
    const h: std.Target.riscv.Feature = .h;
    min_cpu_features.addFeature(@intFromEnum(i));
    min_cpu_features.addFeature(@intFromEnum(m));
    min_cpu_features.addFeature(@intFromEnum(a));
    min_cpu_features.addFeature(@intFromEnum(c));
    min_cpu_features.addFeature(@intFromEnum(h));

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

    const interface_module = b.createModule(.{
        .root_source_file = b.path("hypervisor/interface/lib.zig"),
    });

    // Allow user to select the guest Root VM architecture
    const guest_arch_opt = b.option([]const u8, "guest-arch", "Select the guest architecture to build for: riscv64, riscv32, aarch64, aarch32, x86_64, mips, mips64, ppc") orelse "riscv64";

    const config_filename = try std.fmt.allocPrint(b.allocator, "boot/{s}-linux-busybox-micropython.config", .{guest_arch_opt});
    defer b.allocator.free(config_filename);

    const rootvm_elf_path = b.fmt("zig-out/guest-{s}/bin/rootvm.elf", .{guest_arch_opt});
    const buildroot_dir = b.fmt("zig-out/buildroot-{s}", .{guest_arch_opt});

    const run_buildroot = b.addSystemCommand(&.{ "bash", "scripts/build_rootvm.sh" });
    run_buildroot.addFileArg(b.path(config_filename));
    run_buildroot.addArg(rootvm_elf_path);
    run_buildroot.addArg(buildroot_dir);
    run_buildroot.addArg(guest_arch_opt);


    // Build Unicorn static library via wrapper script.
    // The script creates the zig-cc compiler wrapper (only if needed) and
    // runs CMake configure + build. Output is redirected to a log file.
    // CMake's own dependency tracking provides incremental builds.
    const unicorn_build_dir = "zig-out/unicorn";
    const cmake_build = b.addSystemCommand(&.{
        "bash", "scripts/build_unicorn.sh",
        b.graph.zig_exe,
        unicorn_build_dir,
    });

    const vmdiosix = b.addExecutable(.{ .name = "vmdiosix", .root_module = b.createModule(.{
        .root_source_file = b.path("hypervisor/core/main.zig"),
        .optimize = optimize,
        .target = target,
        .code_model = .medium,
    }), .linkage = .static });
    vmdiosix.step.dependOn(&run_buildroot.step);
    vmdiosix.step.dependOn(&cmake_build.step);
    vmdiosix.root_module.addImport("interface", interface_module);
    vmdiosix.root_module.addIncludePath(b.path("third_party/unicorn/include"));
    
    const unicorn_libs = [_][]const u8{
        "libunicorn.a",
        "libunicorn-common.a",
        "libaarch64-softmmu.a",
        "libarm-softmmu.a",
        "libm68k-softmmu.a",
        "libmips-softmmu.a",
        "libmips64-softmmu.a",
        "libmips64el-softmmu.a",
        "libmipsel-softmmu.a",
        "libppc-softmmu.a",
        "libppc64-softmmu.a",
        "libriscv32-softmmu.a",
        "libriscv64-softmmu.a",
        "libs390x-softmmu.a",
        "libsparc-softmmu.a",
        "libsparc64-softmmu.a",
        "libtricore-softmmu.a",
        "libx86_64-softmmu.a",
    };
    for (unicorn_libs) |lib_name| {
        vmdiosix.root_module.addObjectFile(b.path(b.fmt("{s}/{s}", .{ unicorn_build_dir, lib_name })));
    }

    // Link the Diosix-side Unicorn glue object (bridges internal QEMU APIs).
    vmdiosix.root_module.addObjectFile(b.path(b.fmt("{s}/unicorn_glue.o", .{unicorn_build_dir})));


    // Dynamically read the modification hash of the rootvm.elf payload if it exists
    var current_hash: []const u8 = "unknown";
    const hash_file_path = b.fmt("zig-out/guest-{s}/bin/rootvm.elf.sha256", .{guest_arch_opt});
    if (b.root.root_dir.handle.readFileAlloc(b.graph.io, hash_file_path, b.allocator, std.Io.Limit.limited(1024))) |content| {
        current_hash = std.mem.trim(u8, content, " \t\r\n");
    } else |_| {}

    const rootvm_elf_abs_path = try b.root.joinString(b.allocator, rootvm_elf_path);
    const rootvm_s_content = try std.fmt.allocPrint(b.allocator,
        \\# Dynamically generated by build.zig. DO NOT EDIT.
        \\# Modification hash: {s}
        \\.section .rootvm, "a"
        \\.global root_vm_start
        \\.global root_vm_end
        \\.balign 4096
        \\root_vm_start:
        \\.incbin "{s}"
        \\root_vm_end:
        \\
    , .{ current_hash, rootvm_elf_abs_path });

    const rootvm_s_step = b.addWriteFiles();
    const rootvm_s_file = rootvm_s_step.add("rootvm.s", rootvm_s_content);

    // include the assembly files and linker script from parsed YAML configuration
    for (port_config.assembly_files) |asm_file| {
        if (std.mem.endsWith(u8, asm_file, "rootvm.s")) {
            continue;
        }
        vmdiosix.root_module.addAssemblyFile(b.path(asm_file));
    }
    vmdiosix.root_module.addAssemblyFile(rootvm_s_file);
    vmdiosix.step.dependOn(&rootvm_s_step.step);

    vmdiosix.setLinkerScript(b.path(port_config.linker_script));

    // Register all dependencies (like consts.s) so modifying any of them triggers a full rebuild
    if (port_config.dependencies.len > 0) {
        var dep_step = b.addWriteFiles();
        for (port_config.dependencies) |dep_file| {
            const filename = std.fs.path.basename(dep_file);
            _ = dep_step.addCopyFile(b.path(dep_file), filename);
        }
        vmdiosix.step.dependOn(&dep_step.step);
    }

    // include build-time config options
    const hypervisor_options = b.addOptions();
    hypervisor_options.addOption(bool, "legacy_cpu", legacy_cpu);
    vmdiosix.root_module.addOptions("config", hypervisor_options);

    // Generate config.s dynamically inside the build cache
    const config_step = b.addWriteFiles();
    _ = config_step.add("config.s", config_s_content);
    vmdiosix.root_module.addIncludePath(config_step.getDirectory());
    vmdiosix.step.dependOn(&config_step.step);

    // include build-time metadata as options available to main.zig
    // this includes boot banner text, and details of the build and current version
    const metadata = b.addOptions();

    metadata.addOption([]const u8, "banner", @embedFile("boot/banner.txt"));
    metadata.addOption([]const u8, "project_version", @embedFile("VERSION"));
    metadata.addOption([]const u8, "git_branch", git_branch);
    metadata.addOption([]const u8, "git_revision", git_revision);
    metadata.addOption([]const u8, "build_date", build_date);
    metadata.addOption([]const u8, "build_user", build_user);
    metadata.addOption([]const u8, "build_hostname", build_hostname);
    metadata.addOption([]const u8, "zig_version", zig_version_opt);
    metadata.addOption([]const u8, "cpu_arch", "riscv64");

    // Compile the metadata object file separately to decouple options invalidation.
    // This holds the versioning strings and is linked to the main executable.
    const metadata_obj = b.addObject(.{
        .name = "metadata_info",
        .root_module = b.createModule(.{
            .root_source_file = b.path("hypervisor/core/metadata.zig"),
            .optimize = optimize,
            .target = target,
        }),
    });
    metadata_obj.root_module.addOptions("metadata", metadata);
    vmdiosix.root_module.addObjectFile(metadata_obj.getEmittedBin());

    const install_step = b.addInstallArtifact(vmdiosix, .{
        .dest_dir = .{ .override = .{ .custom = b.fmt("guest-{s}/bin", .{guest_arch_opt}) } }
    });
    b.getInstallStep().dependOn(&install_step.step);

    const yaml_obj = b.addObject(.{
        .name = "yaml_parser",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scripts/yaml_parser.zig"),
            .optimize = optimize,
            .target = b.graph.host,
        }),
    });
    b.getInstallStep().dependOn(&b.addInstallFile(yaml_obj.getEmittedBin(), "yaml_parser.o").step);

    // create a 'zig build run' command to execute the hypervisor in a suitable emulator
    var qemu_args = ArrayList([]const u8).empty;
    defer qemu_args.deinit(b.allocator);

    var arg_idx: usize = 0;
    while (arg_idx < port_config.run_cmd.len) : (arg_idx += 1) {
        const arg = port_config.run_cmd[arg_idx];
        if (std.mem.eql(u8, arg, "-cpu") and arg_idx + 1 < port_config.run_cmd.len) {
            try qemu_args.append(b.allocator, b.dupe("-cpu"));
            try qemu_args.append(b.allocator, try b.allocator.dupe(u8, qemu_cpu_opt orelse port_config.run_cmd[arg_idx + 1]));
            arg_idx += 1;
        } else {
            try qemu_args.append(b.allocator, try b.allocator.dupe(u8, arg));
        }
    }

    const run_step = b.addSystemCommand(qemu_args.items);
    run_step.step.dependOn(b.getInstallStep());

    // the last argument to qemu is the kernel file to run
    run_step.addArtifactArg(vmdiosix);
    run_step.stdio = .inherit;

    const run_option = b.step("run", "Run the hypervisor");
    run_option.dependOn(&run_step.step);

    // run all the unit tests on the host system
    // tests use a separate module targeting native so the test runner has OS support
    const test_module = b.createModule(.{
        .root_source_file = b.path("hypervisor/core/main.zig"),
        .optimize = optimize,
        .target = b.graph.host,
    });
    test_module.addImport("interface", interface_module);
    test_module.addOptions("config", hypervisor_options);
    const unit_tests = b.addTest(.{
        .root_module = test_module,
        .name = "diosix-unit-tests",
    });

    // Compile and link the metadata info separately for host unit tests
    const test_metadata_obj = b.addObject(.{
        .name = "metadata_info_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("hypervisor/core/metadata.zig"),
            .optimize = optimize,
            .target = b.graph.host,
        }),
    });
    test_metadata_obj.root_module.addOptions("metadata", metadata);
    unit_tests.root_module.addObjectFile(test_metadata_obj.getEmittedBin());

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const yaml_test_module = b.createModule(.{
        .root_source_file = b.path("scripts/yaml_parser.zig"),
        .optimize = optimize,
        .target = b.graph.host,
    });
    const yaml_tests = b.addTest(.{
        .root_module = yaml_test_module,
        .name = "yaml-parser-tests",
    });
    const run_yaml_tests = b.addRunArtifact(yaml_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_yaml_tests.step);
}
