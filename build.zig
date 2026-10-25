// Diosix build management.
//
// Don't invoke this file directly. Instead use `./scripts/build.sh`.
// This wrapper ensures that all necessary build-time metadata is freshly
// captured and passed to the build automatically.
//
// Copyright (c) 2024, 2025, 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const Target = std.Target;
const RISCVextensions = Target.Cpu.Feature.Set;
const layout = @import("build/layout.zon");
const build_qemu = @import("scripts/qemu.zig");

const GuestProfile = enum { rootvm, usable, minimal };

const hypervisor_conf_text = @embedFile(layout.metadata.hypervisor_conf);

fn parseConfU32(comptime key: []const u8) u32 {
    @setEvalBranchQuota(10000);
    var lines = std.mem.splitScalar(u8, hypervisor_conf_text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.indexOfScalar(u8, line, '=')) |eq_idx| {
            const k = std.mem.trim(u8, line[0..eq_idx], " \t");
            const v = std.mem.trim(u8, line[eq_idx + 1 ..], " \t");
            if (std.mem.eql(u8, k, key)) {
                return std.fmt.parseInt(u32, v, 10) catch
                    @compileError("Invalid integer for " ++ key);
            }
        }
    }
    @compileError("Missing key in hypervisor.conf: " ++ key);
}

fn addTreeInputs(
    b: *std.Build,
    cmd: *std.Build.Step.Run,
    rel_dir: []const u8,
) !void {
    b.dependOnDirectoryContents(b.path(rel_dir));
    var dir = try b.root.openDir(
        b.graph.io,
        rel_dir,
        .{ .iterate = true },
    );
    defer dir.close(b.graph.io);

    var walker = try dir.walk(b.allocator);
    defer walker.deinit();

    var paths = std.ArrayList([]const u8).empty;
    defer paths.deinit(b.allocator);

    while (try walker.next(b.graph.io)) |entry| {
        const sub = b.fmt("{s}/{s}", .{ rel_dir, entry.path });
        switch (entry.kind) {
            .directory => b.dependOnDirectoryContents(b.path(sub)),
            .file => try paths.append(b.allocator, sub),
            else => {},
        }
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);
    for (paths.items) |p| cmd.addFileInput(b.path(p));
}

fn addRootvmInputs(b: *std.Build, cmd: *std.Build.Step.Run) !void {
    inline for (layout.rootvm.input_files) |file_path| {
        cmd.addFileInput(b.path(file_path));
    }
    inline for (layout.rootvm.input_dirs) |dir_path| {
        try addTreeInputs(b, cmd, dir_path);
    }
}

fn optStr(
    b: *std.Build,
    n: []const u8,
    d: []const u8,
    v: []const u8,
) []const u8 {
    return b.option([]const u8, n, d) orelse v;
}

fn optBool(b: *std.Build, n: []const u8, d: []const u8, def: bool) bool {
    return b.option(bool, n, d) orelse def;
}

fn optU32(b: *std.Build, name: []const u8, desc: []const u8, def: u32) u32 {
    return b.option(u32, name, desc) orelse def;
}

fn linkMetadataObj(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    name: []const u8,
    metadata: *std.Build.Step.Options,
) void {
    const mod = b.createModule(.{
        .root_source_file = b.path(layout.modules.metadata_root),
        .optimize = exe.root_module.optimize.?,
        .target = exe.root_module.resolved_target.?,
    });
    mod.addOptions("metadata", metadata);
    const obj = b.addObject(.{ .name = name, .root_module = mod });
    exe.root_module.addObjectFile(obj.getEmittedBin());
}

fn addHostTestStep(
    b: *std.Build,
    name: []const u8,
    root_path: []const u8,
    with_interface: bool,
    optimize: std.builtin.OptimizeMode,
    iface: *std.Build.Module,
) *std.Build.Step.Run {
    const mod = b.createModule(.{
        .root_source_file = b.path(root_path),
        .optimize = optimize,
        .target = b.graph.host,
    });
    if (with_interface) {
        mod.addImport("interface", iface);
    }
    if (std.mem.eql(u8, name, "diosix-gui-unit-tests")) {
        mod.addAnonymousImport("questrial_ttf", .{
            .root_source_file = b.path(
                "tools/diosix-gui/assets/Questrial-Regular.ttf",
            ),
        });
        mod.addAnonymousImport("intro_wav", .{
            .root_source_file = b.path("tools/diosix-gui/assets/intro.wav"),
        });
    }
    return b.addRunArtifact(b.addTest(.{ .root_module = mod, .name = name }));
}

pub fn build(b: *std.Build) !void {
    const min_ver = std.SemanticVersion.parse(
        layout.min_zig_version,
    ) catch unreachable;
    const cur_ver = @import("builtin").zig_version;
    if (cur_ver.order(min_ver) == .lt) {
        std.debug.print("Error: Requires Zig 0.17.0+ ({}).\n", .{cur_ver});
        return error.UnsupportedZigVersion;
    }

    const qemu_cpu_opt = b.option([]const u8, "qemu-cpu", "QEMU CPU model");
    const legacy_cpu = optBool(b, "legacy-cpu", "Disable Sstc", false);
    const pmp_fallback = optBool(b, "pmp", "PMP fallback mode", false);
    const smp_cores = optU32(
        b,
        "smp",
        "Number of SMP CPU cores",
        layout.qemu.default_smp,
    );
    const mem_size = optStr(
        b,
        "mem",
        "Emulator memory size (e.g. 2G)",
        layout.qemu.default_mem,
    );
    const qemu_gl_opt = optBool(b, "gl", "Enable OpenGL virgl for GUI", true);
    const qemu_audio_opt = optStr(
        b,
        "qemu-audio",
        "Audio backend",
        layout.qemu.default_audio,
    );
    const qemu_extra_opt = b.option([]const u8, "qemu-extra", "Extra args");
    const qemu_tpm_opt = optBool(b, "tpm", "Enable virtual TPM 2.0", false);
    const qemu_usb_key_opt = b.option([]const u8, "usb-key", "USB key vid:pid");
    const welcome_opt = optBool(b, "welcome", "Force welcome tour", false);

    // We build primarily for riscv64 systems and expect RV64IMAC as a minimum.
    var min_cpu_features = RISCVextensions.empty;
    for ([_]std.Target.riscv.Feature{ .i, .m, .a, .c, .h }) |feat| {
        min_cpu_features.addFeature(@backingInt(feat));
    }

    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_arch = Target.Cpu.Arch.riscv64,
            .os_tag = Target.Os.Tag.freestanding,
            .abi = Target.Abi.none,
            .cpu_model = .{ .explicit = &Target.riscv.cpu.baseline_rv64 },
            .cpu_features_add = min_cpu_features,
        },
    });
    const optimize = b.standardOptimizeOption(.{});
    const interface_module = b.createModule(.{
        .root_source_file = b.path(layout.modules.interface_root),
    });

    const guest_arch_opt = optStr(
        b,
        "guest-arch",
        "Guest arch",
        layout.default_arch,
    );
    const guest_config_opt = b.option([]const u8, "guest-config", "Defconfig");
    const guest_profile_opt = optStr(
        b,
        "guest-profile",
        "Profile",
        layout.default_profile,
    );
    const profile_tag = if (std.meta.stringToEnum(
        GuestProfile,
        guest_profile_opt,
    )) |prof| @tagName(prof) else guest_profile_opt;

    const config_filename = guest_config_opt orelse
        b.fmt(layout.rootvm.config_fmt, .{ guest_arch_opt, profile_tag });
    const rootvm_elf_path =
        b.fmt(layout.rootvm.elf_out_fmt, .{guest_arch_opt});
    const buildroot_dir =
        b.fmt(layout.rootvm.buildroot_dir_fmt, .{guest_arch_opt});

    const run_buildroot =
        b.addSystemCommand(&.{ "bash", layout.rootvm.build_script });
    run_buildroot.addFileArg(b.path(config_filename));
    run_buildroot.addArgs(&.{ rootvm_elf_path, buildroot_dir, guest_arch_opt });
    const rootvm_s_file =
        run_buildroot.addOutputFileArg(layout.rootvm.embedded_asm_name);
    try addRootvmInputs(b, run_buildroot);
    run_buildroot.stdio = .inherit;

    const emulation_module = b.createModule(.{
        .root_source_file = b.path(layout.modules.emulation_root),
    });
    emulation_module.addImport("interface", interface_module);

    const vmdiosix = b.addExecutable(.{
        .name = layout.hypervisor.name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(layout.modules.hypervisor_root),
            .optimize = optimize,
            .target = target,
            .code_model = .medium,
        }),
        .linkage = .static,
    });
    vmdiosix.root_module.addImport("interface", interface_module);
    vmdiosix.root_module.addImport("emulation", emulation_module);

    inline for (layout.hypervisor.asm_sources) |asm_file| {
        vmdiosix.root_module.addAssemblyFile(b.path(asm_file));
    }
    vmdiosix.root_module.addAssemblyFile(rootvm_s_file);
    vmdiosix.setLinkerScript(b.path(layout.hypervisor.linker_script));

    const dep_step = b.addWriteFiles();
    _ = dep_step.addCopyFile(
        b.path(layout.hypervisor.asm_consts_src),
        layout.hypervisor.asm_consts_name,
    );
    _ = dep_step.add(
        layout.hypervisor.asm_config_name,
        b.fmt(
            "# Generated.\n.equ LEGACY_CPU, {d}\n",
            .{@intFromBool(legacy_cpu)},
        ),
    );
    vmdiosix.root_module.addIncludePath(dep_step.getDirectory());
    vmdiosix.step.dependOn(&dep_step.step);

    const def_ram_min = comptime parseConfU32("ROOT_RAM_MIN_MB");
    const def_ram_max = comptime parseConfU32("ROOT_RAM_MAX_MB");
    const def_ram_div = comptime parseConfU32("ROOT_RAM_HOST_DIVISOR");
    const def_vcpus = comptime parseConfU32("ROOT_VCPUS_MAX");
    const def_child_ram = comptime parseConfU32("CHILD_RAM_DEFAULT_MB");
    const def_emu_vcores = comptime parseConfU32("MAX_EMULATED_VCORES");
    const def_batch_sz = comptime parseConfU32("INSTRUCTION_BATCH_SIZE");

    const hypervisor_options = b.addOptions();
    hypervisor_options.addOption(bool, "legacy_cpu", legacy_cpu);
    for ([_]struct { []const u8, []const u8, []const u8, bool }{
        .{ "compile_ns16550", "driver-ns16550", "NS16550 driver", true },
        .{ "compile_clint", "driver-clint", "CLINT timer driver", true },
        .{ "compile_sifive_test", "driver-sifive-test", "SiFive test", true },
        .{ "enable_gdb", "gdb", "Enable embedded GDB RSP stub", false },
    }) |opt| {
        const val = optBool(b, opt[1], opt[2], opt[3]);
        hypervisor_options.addOption(bool, opt[0], val);
    }
    for ([_]struct { []const u8, []const u8, []const u8, u32 }{
        .{ "root_ram_min_mb", "root-ram-min-mb", "Min Root RAM", def_ram_min },
        .{ "root_ram_max_mb", "root-ram-max-mb", "Max Root RAM", def_ram_max },
        .{ "root_ram_divisor", "root-ram-divisor", "RAM divisor", def_ram_div },
        .{ "root_vcpus_max", "root-vcpus-max", "Max Root vCPUs", def_vcpus },
        .{
            "child_ram_default_mb",
            "child-ram-default-mb",
            "Default Child RAM (MiB)",
            def_child_ram,
        },
        .{
            "max_emulated_vcores",
            "max-emulated-vcores",
            "Max emulated vCores",
            def_emu_vcores,
        },
        .{
            "instruction_batch_size",
            "instruction-batch-size",
            "Dynarec batch size",
            def_batch_sz,
        },
    }) |opt| {
        const val = optU32(b, opt[1], opt[2], opt[3]);
        hypervisor_options.addOption(u32, opt[0], val);
    }
    vmdiosix.root_module.addOptions("config", hypervisor_options);

    const metadata = b.addOptions();
    metadata.addOption(
        []const u8,
        "banner",
        @embedFile(layout.metadata.banner_file),
    );
    metadata.addOption(
        []const u8,
        "project_version",
        @embedFile(layout.metadata.version_file),
    );
    for ([_][2][]const u8{
        .{ "git_branch", "Current git branch" },
        .{ "git_revision", "Current git rev" },
        .{ "build_date", "Build date" },
        .{ "build_user", "Build user" },
        .{ "build_hostname", "Build host" },
        .{ "zig_version", "Current zig version" },
    }) |m| {
        const val = optStr(b, m[0], m[1], "unknown");
        metadata.addOption([]const u8, m[0], val);
    }
    metadata.addOption([]const u8, "cpu_arch", layout.default_arch);
    linkMetadataObj(b, vmdiosix, layout.metadata.object_name, metadata);

    const dest_override: std.Build.InstallDir = .{
        .custom = b.fmt(layout.rootvm.install_dir_fmt, .{guest_arch_opt}),
    };
    const install_opts: std.Build.Step.InstallArtifact.Options =
        .{ .dest_dir = .{ .override = dest_override } };
    b.getInstallStep().dependOn(
        &b.addInstallArtifact(vmdiosix, install_opts).step,
    );

    const guest_shim = b.addExecutable(.{
        .name = layout.guest_shim.name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(layout.guest_shim.root_source),
            .optimize = optimize,
            .target = target,
            .code_model = .medium,
        }),
        .linkage = .static,
    });
    guest_shim.root_module.addImport("interface", interface_module);
    guest_shim.setLinkerScript(b.path(layout.guest_shim.linker_script));
    b.getInstallStep().dependOn(
        &b.addInstallArtifact(guest_shim, install_opts).step,
    );

    try build_qemu.registerQemuSteps(b, .{
        .vmdiosix = vmdiosix,
        .run_buildroot = run_buildroot,
        .rootvm_elf_path = rootvm_elf_path,
        .legacy_cpu = legacy_cpu,
        .pmp_fallback = pmp_fallback,
        .smp_cores = smp_cores,
        .mem_size = mem_size,
        .qemu_cpu_opt = qemu_cpu_opt,
        .qemu_gl_opt = qemu_gl_opt,
        .qemu_audio_opt = qemu_audio_opt,
        .qemu_extra_opt = qemu_extra_opt,
        .qemu_tpm_opt = qemu_tpm_opt,
        .qemu_usb_key_opt = qemu_usb_key_opt,
        .welcome_opt = welcome_opt,
    });

    // Run all unit tests on the host system.
    const test_module = b.createModule(.{
        .root_source_file = b.path(layout.modules.hypervisor_root),
        .optimize = optimize,
        .target = b.graph.host,
    });
    test_module.addImport("interface", interface_module);
    test_module.addImport("emulation", emulation_module);
    test_module.addOptions("config", hypervisor_options);
    const unit_tests = b.addTest(.{
        .root_module = test_module,
        .name = layout.tests.hypervisor_test_name,
    });
    linkMetadataObj(b, unit_tests, layout.metadata.test_object_name, metadata);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    inline for (layout.tests.host_suites) |suite| {
        const run_t = addHostTestStep(
            b,
            suite.name,
            suite.root,
            suite.with_interface,
            optimize,
            interface_module,
        );
        test_step.dependOn(&run_t.step);
    }

    const run_integration = b.addSystemCommand(&.{
        layout.tests.integration_runner,
        layout.tests.integration_script,
    });
    run_integration.step.dependOn(b.getInstallStep());
    b.step("test-integration", "Run full-stack QEMU integration test suite")
        .dependOn(&run_integration.step);
}
