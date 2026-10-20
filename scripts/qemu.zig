// Diosix QEMU runner and disk image build steps.
//
// Copyright (c) 2024, 2025, 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const ArrayList = std.ArrayList;
const layout = @import("../build/layout.zon");

const AudioBackend = enum { auto, pipewire, pa, alsa, sdl, wav, none };

pub const DEFAULT_DISPLAY_WIDTH: u32 = layout.qemu.display_width;
pub const DEFAULT_DISPLAY_HEIGHT: u32 = layout.qemu.display_height;

fn appendTpmArgs(b: *std.Build, args: *ArrayList([]const u8)) !void {
    const sock_arg = "socket,id=chrtpm,path=" ++ layout.qemu.swtpm_socket;
    try args.appendSlice(b.allocator, &.{
        "-chardev", sock_arg,
        "-tpmdev",  "emulator,id=tpm0,chardev=chrtpm",
        "-device",  "tpm-tis-device,tpmdev=tpm0",
    });
}

fn appendBootArgs(
    b: *std.Build,
    args: *ArrayList([]const u8),
    s: []const u8,
) !void {
    try args.appendSlice(
        b.allocator,
        &.{ "-append", s, "-bios", "none", "-kernel" },
    );
}

const QemuRunner = struct {
    b: *std.Build,
    kernel: *std.Build.Step.Compile,

    fn add(
        self: QemuRunner,
        disk: *std.Build.Step,
        tpm: ?*std.Build.Step,
        name: []const u8,
        desc: []const u8,
        argv: []const []const u8,
    ) void {
        const cmd = self.b.addSystemCommand(argv);
        if (tpm) |t| cmd.step.dependOn(t);
        cmd.step.dependOn(self.b.getInstallStep());
        cmd.step.dependOn(disk);
        cmd.addArtifactArg(self.kernel);
        cmd.stdio = .inherit;
        self.b.step(name, desc).dependOn(&cmd.step);
    }
};

pub const QemuConfig = struct {
    vmdiosix: *std.Build.Step.Compile,
    run_buildroot: *std.Build.Step.Run,
    rootvm_elf_path: []const u8,
    legacy_cpu: bool,
    pmp_fallback: bool,
    smp_cores: u32,
    mem_size: []const u8,
    qemu_cpu_opt: ?[]const u8,
    qemu_gl_opt: bool,
    qemu_audio_opt: []const u8,
    qemu_extra_opt: ?[]const u8,
    qemu_tpm_opt: bool,
    qemu_usb_key_opt: ?[]const u8,
    welcome_opt: bool,
};

pub fn registerQemuSteps(b: *std.Build, cfg: QemuConfig) !void {
    var qemu_args = ArrayList([]const u8).empty;
    defer qemu_args.deinit(b.allocator);

    const h_flag = if (cfg.pmp_fallback) "false" else "true";
    const ext_flag = if (cfg.legacy_cpu) "false" else "true";
    const cpu_arg = cfg.qemu_cpu_opt orelse b.fmt(
        "rv64,h={s},smstateen={s},sstc={s},v=true",
        .{ h_flag, ext_flag, ext_flag },
    );

    const storage_img_path = layout.qemu.storage_img;
    const storage_drive_arg =
        "file=" ++ storage_img_path ++ ",if=none,format=raw,id=hd0";
    const create_storage_cmd = b.addSystemCommand(&.{
        "bash",                   layout.qemu.storage_script,
        cfg.rootvm_elf_path,      storage_img_path,
        layout.qemu.storage_size,
    });
    create_storage_cmd.addFileInput(b.path(layout.qemu.storage_script));
    create_storage_cmd.step.dependOn(&cfg.run_buildroot.step);

    try qemu_args.appendSlice(b.allocator, &.{
        layout.qemu.system_bin,          "-nographic",
        "-s",                            "-machine",
        "virt",                          "-cpu",
        cpu_arg,                         "-smp",
        b.fmt("{d}", .{cfg.smp_cores}),  "-m",
        cfg.mem_size,                    "-drive",
        storage_drive_arg,               "-device",
        "virtio-blk-device,drive=hd0",   "-netdev",
        "user,id=net0",                  "-device",
        "virtio-net-device,netdev=net0",
    });

    const setup_tpm_cmd = b.addSystemCommand(
        &.{ "bash", layout.qemu.swtpm_script, "start" },
    );
    const opt_tpm_step: ?*std.Build.Step =
        if (cfg.qemu_tpm_opt) &setup_tpm_cmd.step else null;
    const dev_append_str = if (cfg.welcome_opt)
        "diosix.mode=dev diosix.welcome=force"
    else
        "diosix.mode=dev";

    const qemu = QemuRunner{ .b = b, .kernel = cfg.vmdiosix };
    var run_step_args = ArrayList([]const u8).empty;
    defer run_step_args.deinit(b.allocator);
    try run_step_args.appendSlice(b.allocator, qemu_args.items);
    if (cfg.qemu_tpm_opt) try appendTpmArgs(b, &run_step_args);
    try appendBootArgs(b, &run_step_args, dev_append_str);
    qemu.add(
        &create_storage_cmd.step,
        opt_tpm_step,
        "run",
        "Run the hypervisor",
        run_step_args.items,
    );

    const live_img_path = layout.qemu.live_img;
    const create_live_cmd =
        b.addSystemCommand(&.{ "bash", layout.qemu.live_script });
    create_live_cmd.addFileInput(b.path(layout.qemu.live_script));
    create_live_cmd.addFileArg(cfg.vmdiosix.getEmittedBin());
    create_live_cmd.addArgs(&.{
        cfg.rootvm_elf_path,
        live_img_path,
        layout.qemu.live_size_mb,
    });
    create_live_cmd.step.dependOn(b.getInstallStep());
    create_live_cmd.step.dependOn(&cfg.run_buildroot.step);
    b.step("live-image", "Build bootable hybrid GPT live & installer image")
        .dependOn(&create_live_cmd.step);

    var qemu_live_args = ArrayList([]const u8).empty;
    defer qemu_live_args.deinit(b.allocator);
    for (qemu_args.items) |arg| {
        const replaced = if (std.mem.eql(u8, arg, storage_drive_arg))
            "file=" ++ live_img_path ++ ",if=none,format=raw,id=hd0"
        else
            arg;
        try qemu_live_args.append(b.allocator, replaced);
    }
    try appendBootArgs(b, &qemu_live_args, "diosix.mode=live");
    qemu.add(
        &create_live_cmd.step,
        null,
        "run-live",
        "Run the hypervisor with the live GPT disk image",
        qemu_live_args.items,
    );

    var qemu_gui_args = ArrayList([]const u8).empty;
    defer qemu_gui_args.deinit(b.allocator);
    for (qemu_args.items) |arg| {
        if (std.mem.eql(u8, arg, "-nographic")) {
            try qemu_gui_args.appendSlice(
                b.allocator,
                &.{ "-serial", "mon:stdio" },
            );
        } else try qemu_gui_args.append(b.allocator, arg);
    }
    const gpu_dev = if (cfg.qemu_gl_opt)
        b.fmt("virtio-gpu-gl-pci,xres={d},yres={d}", .{
            DEFAULT_DISPLAY_WIDTH,
            DEFAULT_DISPLAY_HEIGHT,
        })
    else
        b.fmt("virtio-gpu-pci,xres={d},yres={d}", .{
            DEFAULT_DISPLAY_WIDTH,
            DEFAULT_DISPLAY_HEIGHT,
        });
    if (cfg.qemu_gl_opt) {
        try qemu_gui_args.appendSlice(b.allocator, &.{
            "-display", "gtk,gl=on,zoom-to-fit=off",
            "-device",  gpu_dev,
        });
    } else {
        try qemu_gui_args.appendSlice(b.allocator, &.{ "-device", gpu_dev });
    }
    try qemu_gui_args.appendSlice(b.allocator, &.{
        "-device", "virtio-keyboard-pci",
        "-device", "virtio-tablet-pci",
    });

    const parsed_audio = std.meta.stringToEnum(
        AudioBackend,
        cfg.qemu_audio_opt,
    );
    const audio_backend: []const u8 = if (parsed_audio) |backend|
        switch (backend) {
            .auto => blk: {
                if (b.graph.environ_map.get("XDG_RUNTIME_DIR")) |xdg| {
                    const pw_path = b.fmt("{s}/pipewire-0", .{xdg});
                    if (std.Io.Dir.cwd().access(b.graph.io, pw_path, .{})) |_| {
                        break :blk "pipewire";
                    } else |_| {}
                }
                break :blk "pa";
            },
            else => @tagName(backend),
        }
    else
        cfg.qemu_audio_opt;

    if (parsed_audio == null or parsed_audio.? != .none) {
        try qemu_gui_args.appendSlice(b.allocator, &.{
            "-audiodev", b.fmt("{s},id=audio0", .{audio_backend}),
            "-device",   "intel-hda",
            "-device",   "hda-duplex,audiodev=audio0",
        });
    }
    if (cfg.qemu_usb_key_opt) |key| {
        const dev_arg = if (std.mem.indexOfScalar(u8, key, ':')) |colon_idx|
            b.fmt(
                "usb-host,bus=xhci.0,vendorid=0x{s},productid=0x{s}",
                .{ key[0..colon_idx], key[colon_idx + 1 ..] },
            )
        else if (std.mem.startsWith(u8, key, "/dev/hidraw"))
            b.fmt("u2f-passthru,bus=xhci.0,hidraw={s}", .{key})
        else
            b.fmt("usb-host,bus=xhci.0,hostdevice={s}", .{key});
        try qemu_gui_args.appendSlice(b.allocator, &.{
            "-device", "qemu-xhci,id=xhci", "-device", dev_arg,
        });
    }
    if (cfg.qemu_tpm_opt) try appendTpmArgs(b, &qemu_gui_args);
    if (cfg.qemu_extra_opt) |extra| {
        var it = std.mem.tokenizeScalar(u8, extra, ' ');
        while (it.next()) |tok| try qemu_gui_args.append(b.allocator, tok);
    }
    try appendBootArgs(b, &qemu_gui_args, dev_append_str);
    qemu.add(
        &create_storage_cmd.step,
        opt_tpm_step,
        "run-gui",
        "Run the hypervisor with VirtIO-GPU and GUI window",
        qemu_gui_args.items,
    );

    var qemu_tpm_args = ArrayList([]const u8).empty;
    defer qemu_tpm_args.deinit(b.allocator);
    for (qemu_gui_args.items) |arg| {
        if (std.mem.eql(u8, arg, "-bios") and !cfg.qemu_tpm_opt) {
            try appendTpmArgs(b, &qemu_tpm_args);
        }
        try qemu_tpm_args.append(b.allocator, arg);
    }
    qemu.add(
        &create_storage_cmd.step,
        &setup_tpm_cmd.step,
        "run-tpm",
        "Run the hypervisor GUI with virtual TPM 2.0 (swtpm)",
        qemu_tpm_args.items,
    );
}

test {
    std.testing.refAllDecls(@This());
}
