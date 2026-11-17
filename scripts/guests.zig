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
    desktop_stamp: ?std.Build.LazyPath,
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

    const on_demand_desktop = try addChildGuestStep(
        b,
        guest_arch,
        layout.guests.desktop,
        "guest-desktop.stamp",
        null,
    );
    b.step("guest-desktop", "Build optional linux-desktop.elf guest image")
        .dependOn(&on_demand_desktop.run.step);

    var res = GuestBuildResult{
        .extra_guests = extra_guests,
        .guest_images_step = null,
        .cli_stamp = null,
        .desktop_stamp = null,
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
        const desktop_guest = try addChildGuestStep(
            b,
            guest_arch,
            layout.guests.desktop,
            "linux-desktop.stamp",
            &cli_guest.run.step,
        );
        res.guest_images_step = &desktop_guest.run.step;
        res.cli_stamp = cli_guest.stamp;
        res.desktop_stamp = desktop_guest.stamp;
    }
    return res;
}

test {
    std.testing.refAllDecls(@This());
}
