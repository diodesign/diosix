// Optional legacy guest image steps and shared directory input helpers.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const layout = @import("../build/layout.zon");

pub const GuestBuildResult = struct {
    extra_guests: bool,
    guest_images_step: ?*std.Build.Step,
    cli_stamp: ?std.Build.LazyPath,
};

pub fn addTreeInputs(
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

pub fn addRootvmInputs(b: *std.Build, cmd: *std.Build.Step.Run) !void {
    inline for (layout.rootvm.input_files) |file_path| {
        cmd.addFileInput(b.path(file_path));
    }
    inline for (layout.rootvm.input_dirs) |dir_path| {
        try addTreeInputs(b, cmd, dir_path);
    }
}

fn addChildGuestStep(
    b: *std.Build,
    guest_arch: []const u8,
    spec: anytype,
    stamp_name: []const u8,
    prev_step: ?*std.Build.Step,
) !struct { run: *std.Build.Step.Run, stamp: std.Build.LazyPath } {
    const cfg_file = b.fmt(
        layout.rootvm.config_fmt,
        .{ guest_arch, spec.profile },
    );
    const elf_out = b.fmt(spec.elf_out_fmt, .{guest_arch});
    const br_dir = b.fmt(spec.buildroot_dir_fmt, .{guest_arch});
    const cmd = b.addSystemCommand(&.{ "bash", layout.rootvm.build_script });
    cmd.addFileArg(b.path(cfg_file));
    cmd.addArgs(&.{ elf_out, br_dir, guest_arch });
    const stamp = cmd.addOutputFileArg(stamp_name);
    cmd.addArg(spec.overlay_dir);
    inline for (layout.rootvm.input_files) |file_path| {
        cmd.addFileInput(b.path(file_path));
    }
    inline for (layout.guests.common_input_dirs) |dir_path| {
        try addTreeInputs(b, cmd, dir_path);
    }
    try addTreeInputs(b, cmd, spec.overlay_dir);
    if (prev_step) |ps| cmd.step.dependOn(ps);
    cmd.stdio = .inherit;
    return .{ .run = cmd, .stamp = stamp };
}

pub fn registerGuestSteps(
    b: *std.Build,
    guest_arch: []const u8,
    profile_tag: []const u8,
    has_custom_cfg: bool,
    extra_guests: bool,
    base_step: *std.Build.Step,
) !GuestBuildResult {
    const on_demand_cli = try addChildGuestStep(
        b,
        guest_arch,
        layout.guests.cli,
        "guest-cli.stamp",
        null,
    );
    b.step("guest-cli", "Build optional linux-cli.elf guest image")
        .dependOn(&on_demand_cli.run.step);

    var res = GuestBuildResult{
        .extra_guests = extra_guests,
        .guest_images_step = null,
        .cli_stamp = null,
    };

    if (extra_guests and
        std.mem.eql(u8, profile_tag, layout.default_profile) and
        !has_custom_cfg)
    {
        const cli_guest = try addChildGuestStep(
            b,
            guest_arch,
            layout.guests.cli,
            "linux-cli.stamp",
            base_step,
        );
        res.guest_images_step = &cli_guest.run.step;
        res.cli_stamp = cli_guest.stamp;
    }
    return res;
}

pub fn registerSdkStep(
    b: *std.Build,
    arch_str: []const u8,
    optimize: std.builtin.OptimizeMode,
    iface: *std.Build.Module,
) *std.Build.Step {
    const Target = std.Target;
    const cpu_arch = std.meta.stringToEnum(
        Target.Cpu.Arch,
        arch_str,
    ) orelse .riscv64;
    const sdk_target = b.resolveTargetQuery(.{
        .cpu_arch = cpu_arch,
        .os_tag = .linux,
        .abi = .musl,
    });
    const sdk_dir: std.Build.InstallDir = .{
        .custom = b.fmt("sdk-{s}", .{arch_str}),
    };
    const lib_dir: std.Build.InstallDir = .{
        .custom = b.fmt("sdk-{s}/lib", .{arch_str}),
    };

    const static_mod = b.createModule(.{
        .root_source_file = b.path(layout.modules.libdiosix_c_abi),
        .optimize = optimize,
        .target = sdk_target,
        .pic = true,
    });
    static_mod.addImport("interface", iface);
    const lib_static = b.addLibrary(.{
        .linkage = .static,
        .name = layout.libdiosix.name,
        .root_module = static_mod,
    });

    const shared_mod = b.createModule(.{
        .root_source_file = b.path(layout.modules.libdiosix_c_abi),
        .optimize = optimize,
        .target = sdk_target,
        .pic = true,
    });
    shared_mod.addImport("interface", iface);
    const lib_shared = b.addLibrary(.{
        .linkage = .dynamic,
        .name = layout.libdiosix.name,
        .root_module = shared_mod,
    });

    const ver = std.mem.trim(
        u8,
        @embedFile("../" ++ layout.metadata.version_file),
        " \t\r\n",
    );
    const pc_files = b.addWriteFiles();
    const pc_path = pc_files.add("diosix.pc", b.fmt(
        \\prefix=/usr
        \\libdir=${{prefix}}/lib
        \\includedir=${{prefix}}/include
        \\
        \\Name: libdiosix
        \\Description: Diosix hypervisor userland control library
        \\Version: {s}
        \\Libs: -L${{libdir}} -ldiosix
        \\Cflags: -I${{includedir}}
        \\
    , .{ver}));

    const sdk_step = b.step(
        "sdk",
        "Build cross-compiled libdiosix static and shared SDK",
    );
    for ([_]*std.Build.Step{
        &b.addInstallArtifact(
            lib_static,
            .{ .dest_dir = .{ .override = lib_dir } },
        ).step,
        &b.addInstallArtifact(
            lib_shared,
            .{ .dest_dir = .{ .override = lib_dir } },
        ).step,
        &b.addInstallFileWithDir(
            b.path(layout.libdiosix.header),
            sdk_dir,
            "include/diosix.h",
        ).step,
        &b.addInstallFileWithDir(
            pc_path,
            sdk_dir,
            "lib/pkgconfig/diosix.pc",
        ).step,
        &b.addInstallFileWithDir(
            b.path(layout.libdiosix.example),
            sdk_dir,
            "examples/vm_info.c",
        ).step,
    }) |st| {
        sdk_step.dependOn(st);
    }
    return sdk_step;
}

test {
    std.testing.refAllDecls(@This());
}
