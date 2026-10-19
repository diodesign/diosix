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
const build_qemu = @import("scripts/qemu.zig");

const GuestProfile = enum { rootvm, usable, minimal };

const ctl_sources = [_][]const u8{
    "main.zig",      "api.zig",         "auth.zig",      "catalog.zig",
    "charter.zig",   "charter/cmd.zig", "common.zig",    "governance.zig",
    "gui.zig",       "host.zig",        "image.zig",     "image/pull.zig",
    "installer.zig", "loader.zig",      "manifest.zig",  "manifest/policy.zig",
    "passkey.zig",   "registry.zig",    "snapshot.zig",  "ssh.zig",
    "ssh/sync.zig",  "storage.zig",     "sysconfig.zig", "vm.zig",
    "vm/info.zig",   "vm/install.zig",  "vm/run.zig",    "vm/stage.zig",
    "whisper.zig",
};
const gui_sources = [_][]const u8{
    "main.zig",             "audio.zig",         "backdrop.zig",
    "cursor.zig",           "display.zig",       "drm.zig",
    "font.zig",             "font/banner.zig",   "font/banner_font.bin",
    "font/banner_glow.bin", "framebuffer.zig",   "glass.zig",
    "gui.zig",              "gui/input.zig",     "gui/nav.zig",
    "gui/render.zig",       "host.zig",          "icon.zig",
    "icon/render.zig",      "icon/viewport.zig", "intro.zig",
    "intro/fx.zig",         "noise.zig",         "osk.zig",
    "panes.zig",            "panes/catalog.zig", "panes/modal.zig",
    "panes/vm.zig",         "tests.zig",         "welcome.zig",
    "window.zig",           "window/input.zig",  "cloud_map.bin",
};
const overlay_configs = [_][]const u8{
    "constitution.md", "charter.toml", "diosix.toml",
    "install.toml",    "catalog.toml", "system.toml",
};
const extra_rootvm_inputs = [_][]const u8{
    "scripts/build_rootvm.sh",          "tools/diosix-config/src/main.zig",
    "tools/diosix-config/src/ui.zig",   "tools/guest-shim/src/main.zig",
    "tools/guest-shim/src/loader.zig",  "tools/guest-shim/src/efi.zig",
    "tools/guest-shim/src/storage.zig", "tools/alsa-init/main.c",
    "tools/driver/diosix.h",            "tools/driver/diosix.c",
    "tools/driver/governance.c",        "tools/driver/net.c",
};

fn addRootvmInputs(b: *std.Build, cmd: *std.Build.Step.Run) void {
    for (extra_rootvm_inputs) |p| cmd.addFileInput(b.path(p));
    for (ctl_sources) |f| {
        cmd.addFileInput(b.path(b.fmt("tools/diosix-ctl/src/{s}", .{f})));
    }
    for (gui_sources) |f| {
        cmd.addFileInput(b.path(b.fmt("tools/diosix-gui/src/{s}", .{f})));
    }
    for (overlay_configs) |f| {
        const p = b.fmt("tools/overlay-common/etc/diosix/{s}", .{f});
        cmd.addFileInput(b.path(p));
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
        .root_source_file = b.path("hypervisor/core/metadata.zig"),
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
    optimize: std.builtin.OptimizeMode,
    iface: *std.Build.Module,
) *std.Build.Step.Run {
    const mod = b.createModule(.{
        .root_source_file = b.path(root_path),
        .optimize = optimize,
        .target = b.graph.host,
    });
    if (!std.mem.endsWith(u8, root_path, "interface/lib.zig")) {
        mod.addImport("interface", iface);
    }
    return b.addRunArtifact(b.addTest(.{ .root_module = mod, .name = name }));
}

pub fn build(b: *std.Build) !void {
    // Ensure host compiler meets minimum version requirements (Zig 0.17.0+).
    const min_ver = std.SemanticVersion.parse("0.17.0-dev") catch unreachable;
    const cur_ver = @import("builtin").zig_version;
    if (cur_ver.order(min_ver) == .lt) {
        std.debug.print("Error: Requires Zig 0.17.0+ ({}).\n", .{cur_ver});
        return error.UnsupportedZigVersion;
    }

    const qemu_cpu_opt = b.option([]const u8, "qemu-cpu", "QEMU CPU model");
    const legacy_cpu = optBool(b, "legacy-cpu", "Disable Sstc", false);
    const pmp_fallback = optBool(b, "pmp", "PMP fallback mode", false);
    const smp_cores = optU32(b, "smp", "Number of SMP CPU cores", 4);
    const mem_size = optStr(b, "mem", "Emulator memory size (e.g. 2G)", "2G");
    const qemu_gl_opt = optBool(b, "gl", "Enable OpenGL virgl for GUI", true);
    const qemu_audio_opt = optStr(b, "qemu-audio", "Audio backend", "auto");
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
        .root_source_file = b.path("hypervisor/interface/lib.zig"),
    });

    const guest_arch_opt = optStr(b, "guest-arch", "Guest arch", "riscv64");
    const guest_config_opt = b.option([]const u8, "guest-config", "Defconfig");
    const guest_profile_opt = optStr(b, "guest-profile", "Profile", "rootvm");
    const profile_tag = if (std.meta.stringToEnum(
        GuestProfile,
        guest_profile_opt,
    )) |prof| @tagName(prof) else guest_profile_opt;

    const config_filename = guest_config_opt orelse
        b.fmt("boot/{s}-linux-{s}.config", .{ guest_arch_opt, profile_tag });
    const rootvm_elf_path =
        b.fmt("zig-out/guest-{s}/bin/rootvm.elf", .{guest_arch_opt});
    const buildroot_dir = b.fmt("zig-out/buildroot-{s}", .{guest_arch_opt});

    const run_buildroot =
        b.addSystemCommand(&.{ "bash", "scripts/build_rootvm.sh" });
    run_buildroot.addFileArg(b.path(config_filename));
    run_buildroot.addArgs(&.{ rootvm_elf_path, buildroot_dir, guest_arch_opt });
    const rootvm_s_file = run_buildroot.addOutputFileArg("rootvm.s");
    addRootvmInputs(b, run_buildroot);
    run_buildroot.stdio = .inherit;

    const emulation_module = b.createModule(.{
        .root_source_file = b.path("hypervisor/hardware/emulation/mod.zig"),
    });
    emulation_module.addImport("interface", interface_module);

    const vmdiosix = b.addExecutable(.{
        .name = "vmdiosix",
        .root_module = b.createModule(.{
            .root_source_file = b.path("hypervisor/main.zig"),
            .optimize = optimize,
            .target = target,
            .code_model = .medium,
        }),
        .linkage = .static,
    });
    vmdiosix.root_module.addImport("interface", interface_module);
    vmdiosix.root_module.addImport("emulation", emulation_module);

    for ([_][]const u8{
        "hypervisor/hardware/native/cpu/riscv64/entry.s",
        "hypervisor/hardware/native/cpu/riscv64/xint.s",
        "hypervisor/hardware/native/cpu/riscv64/util.s",
    }) |asm_file| vmdiosix.root_module.addAssemblyFile(b.path(asm_file));
    vmdiosix.root_module.addAssemblyFile(rootvm_s_file);
    vmdiosix.setLinkerScript(
        b.path("hypervisor/hardware/native/cpu/riscv64/linker.ld"),
    );

    const dep_step = b.addWriteFiles();
    _ = dep_step.addCopyFile(
        b.path("hypervisor/hardware/native/cpu/riscv64/consts.s"),
        "consts.s",
    );
    _ = dep_step.add(
        "config.s",
        b.fmt(
            "# Generated.\n.equ LEGACY_CPU, {d}\n",
            .{@intFromBool(legacy_cpu)},
        ),
    );
    vmdiosix.root_module.addIncludePath(dep_step.getDirectory());
    vmdiosix.step.dependOn(&dep_step.step);

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
        .{ "root_ram_min_mb", "root-ram-min-mb", "Min Root VM RAM (MiB)", 128 },
        .{ "root_ram_max_mb", "root-ram-max-mb", "Max Root VM RAM (MiB)", 256 },
        .{ "root_ram_divisor", "root-ram-divisor", "Root VM RAM divisor", 8 },
        .{ "root_vcpus_max", "root-vcpus-max", "Max Root VM vCPUs", 4 },
    }) |opt| {
        const val = optU32(b, opt[1], opt[2], opt[3]);
        hypervisor_options.addOption(u32, opt[0], val);
    }
    vmdiosix.root_module.addOptions("config", hypervisor_options);

    const metadata = b.addOptions();
    metadata.addOption([]const u8, "banner", @embedFile("boot/banner.txt"));
    metadata.addOption([]const u8, "project_version", @embedFile("VERSION"));
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
    metadata.addOption([]const u8, "cpu_arch", "riscv64");
    linkMetadataObj(b, vmdiosix, "metadata_info", metadata);

    const dest_override: std.Build.InstallDir =
        .{ .custom = b.fmt("guest-{s}/bin", .{guest_arch_opt}) };
    const install_opts: std.Build.Step.InstallArtifact.Options =
        .{ .dest_dir = .{ .override = dest_override } };
    b.getInstallStep().dependOn(
        &b.addInstallArtifact(vmdiosix, install_opts).step,
    );

    const guest_shim = b.addExecutable(.{
        .name = "guest-shim-riscv64.elf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/guest-shim/src/main.zig"),
            .optimize = optimize,
            .target = target,
            .code_model = .medium,
        }),
        .linkage = .static,
    });
    guest_shim.setLinkerScript(b.path("tools/guest-shim/linker.ld"));
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
        .root_source_file = b.path("hypervisor/main.zig"),
        .optimize = optimize,
        .target = b.graph.host,
    });
    test_module.addImport("interface", interface_module);
    test_module.addImport("emulation", emulation_module);
    test_module.addOptions("config", hypervisor_options);
    const unit_tests =
        b.addTest(.{ .root_module = test_module, .name = "diosix-unit-tests" });
    linkMetadataObj(b, unit_tests, "metadata_info_test", metadata);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    for ([_][2][]const u8{
        .{ "diosix-ctl-unit-tests", "tools/diosix-ctl/src/main.zig" },
        .{ "diosix-interface-unit-tests", "hypervisor/interface/lib.zig" },
        .{
            "diosix-emulation-unit-tests",
            "hypervisor/hardware/emulation/mod.zig",
        },
        .{ "diosix-gui-unit-tests", "tools/diosix-gui/src/main.zig" },
        .{ "diosix-config-unit-tests", "tools/diosix-config/src/main.zig" },
        .{ "diosix-guest-shim-unit-tests", "tools/guest-shim/src/main.zig" },
    }) |t| {
        const run_t = addHostTestStep(
            b,
            t[0],
            t[1],
            optimize,
            interface_module,
        );
        test_step.dependOn(&run_t.step);
    }

    const run_integration = b.addSystemCommand(
        &.{ "python3", "scripts/test_manifest_integration.py" },
    );
    run_integration.step.dependOn(b.getInstallStep());
    b.step("test-integration", "Run full-stack QEMU integration test suite")
        .dependOn(&run_integration.step);
}
