// Diosix QEMU runner and disk image build steps.
//
// Copyright (c) 2024, 2025, 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const ArrayList = std.ArrayList;
const layout = @import("../build/layout.zon");

fn appendTpmArgs(b: *std.Build, args: *ArrayList([]const u8)) !void {
    const sock_arg = "socket,id=chrtpm,path=" ++ layout.qemu.swtpm_socket;
    try args.appendSlice(b.allocator, &.{
        "-chardev", sock_arg,
        "-tpmdev",  "emulator,id=tpm0,chardev=chrtpm",
        "-device",  "tpm-tis-device,tpmdev=tpm0",
    });
}

fn appendUsbKeyArgs(
    b: *std.Build,
    args: *ArrayList([]const u8),
    usb_key_opt: ?[]const u8,
) !void {
    const key = usb_key_opt orelse return;
    const dev_arg = if (std.mem.indexOfScalar(u8, key, ':')) |colon_idx|
        b.fmt(
            "usb-host,bus=xhci.0,vendorid=0x{s},productid=0x{s}",
            .{ key[0..colon_idx], key[colon_idx + 1 ..] },
        )
    else if (std.mem.startsWith(u8, key, "/dev/hidraw"))
        b.fmt("u2f-passthru,bus=xhci.0,hidraw={s}", .{key})
    else
        b.fmt("usb-host,bus=xhci.0,hostdevice={s}", .{key});
    try args.appendSlice(b.allocator, &.{
        "-device", "qemu-xhci,id=xhci", "-device", dev_arg,
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
    guest_images_step: ?*std.Build.Step,
    rootvm_s_file: std.Build.LazyPath,
    cli_stamp_file: ?std.Build.LazyPath,
    rootvm_elf_path: []const u8,
    edition: []const u8,
    legacy_cpu: bool,
    pmp_fallback: bool,
    smp_cores: u32,
    mem_size: []const u8,
    qemu_cpu_opt: ?[]const u8,
    qemu_extra_opt: ?[]const u8,
    qemu_tpm_opt: bool,
    qemu_usb_key_opt: ?[]const u8,
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
        layout.qemu.storage_size, layout.qemu.iso_cache_dir,
    });
    create_storage_cmd.addFileInput(b.path(layout.qemu.storage_script));
    create_storage_cmd.addFileInput(b.path("scripts/lib/buildroot_common.sh"));
    create_storage_cmd.addFileInput(b.path("scripts/extract_iso_apks.py"));
    create_storage_cmd.addFileInput(cfg.rootvm_s_file);
    if (cfg.cli_stamp_file) |cs| create_storage_cmd.addFileInput(cs);
    create_storage_cmd.step.dependOn(&cfg.run_buildroot.step);
    if (cfg.guest_images_step) |gs| create_storage_cmd.step.dependOn(gs);
    b.getInstallStep().dependOn(&create_storage_cmd.step);

    try qemu_args.appendSlice(b.allocator, &.{
        layout.qemu.system_bin,
        "-nographic",
        "-s",
        "-machine",
        "virt",
        "-cpu",
        cpu_arg,
        "-smp",
        b.fmt("{d}", .{cfg.smp_cores}),
        "-m",
        cfg.mem_size,
        "-drive",
        storage_drive_arg,
        "-device",
        "virtio-blk-device,drive=hd0",
        "-netdev",
        "user,id=net0,hostfwd=tcp::2222-:22",
        "-device",
        "virtio-net-device,netdev=net0",
    });

    const setup_tpm_cmd = b.addSystemCommand(
        &.{ "bash", layout.qemu.swtpm_script, "start" },
    );
    const opt_tpm_step: ?*std.Build.Step =
        if (cfg.qemu_tpm_opt) &setup_tpm_cmd.step else null;

    const qemu = QemuRunner{ .b = b, .kernel = cfg.vmdiosix };
    var run_step_args = ArrayList([]const u8).empty;
    defer run_step_args.deinit(b.allocator);
    try run_step_args.appendSlice(b.allocator, qemu_args.items);
    try appendUsbKeyArgs(b, &run_step_args, cfg.qemu_usb_key_opt);
    if (cfg.qemu_tpm_opt) try appendTpmArgs(b, &run_step_args);
    if (cfg.qemu_extra_opt) |extra| {
        var it = std.mem.tokenizeScalar(u8, extra, ' ');
        while (it.next()) |tok| try run_step_args.append(b.allocator, tok);
    }
    try appendBootArgs(b, &run_step_args, "diosix.mode=dev");
    qemu.add(
        &create_storage_cmd.step,
        opt_tpm_step,
        "run",
        "Run the hypervisor (SSH forwarded on host port 2222)",
        run_step_args.items,
    );

    var run_cli_args = ArrayList([]const u8).empty;
    defer run_cli_args.deinit(b.allocator);
    try run_cli_args.appendSlice(b.allocator, qemu_args.items);
    if (cfg.qemu_tpm_opt) try appendTpmArgs(b, &run_cli_args);
    try appendBootArgs(b, &run_cli_args, "diosix.mode=dev diosix.demo=cli");
    qemu.add(
        &create_storage_cmd.step,
        opt_tpm_step,
        "run-cli",
        "Boot directly into an interactive RISC-V Linux CLI VM",
        run_cli_args.items,
    );

    const live_img_path = layout.qemu.live_img;
    const create_live_cmd =
        b.addSystemCommand(&.{ "bash", layout.qemu.live_script });
    create_live_cmd.addFileInput(b.path(layout.qemu.live_script));
    create_live_cmd.addFileInput(b.path("scripts/lib/buildroot_common.sh"));
    create_live_cmd.addFileInput(b.path("scripts/extract_iso_apks.py"));
    create_live_cmd.addFileInput(cfg.rootvm_s_file);
    if (cfg.cli_stamp_file) |cs| create_live_cmd.addFileInput(cs);
    create_live_cmd.addFileArg(cfg.vmdiosix.getEmittedBin());
    create_live_cmd.addArgs(&.{
        cfg.rootvm_elf_path,
        live_img_path,
        layout.qemu.live_size_mb,
    });
    create_live_cmd.step.dependOn(b.getInstallStep());
    create_live_cmd.step.dependOn(&cfg.run_buildroot.step);
    if (cfg.guest_images_step) |gs| create_live_cmd.step.dependOn(gs);
    b.step("live-image", "Build bootable hybrid GPT live & installer image")
        .dependOn(&create_live_cmd.step);

    const release_cmd = b.addSystemCommand(&.{
        "bash",
        layout.qemu.release_script,
        layout.default_arch,
        cfg.edition,
    });
    release_cmd.addFileInput(b.path(layout.qemu.release_script));
    release_cmd.step.dependOn(&create_live_cmd.step);
    release_cmd.stdio = .inherit;
    b.step("release", "Build edition release bundle and libdiosix SDK")
        .dependOn(&release_cmd.step);

    const swarm_cmd = b.addSystemCommand(&.{
        "python3", "-B", "scripts/run_swarm.py", "--hosts", "2",
    });
    swarm_cmd.addFileInput(b.path("scripts/run_swarm.py"));
    swarm_cmd.step.dependOn(&create_storage_cmd.step);
    swarm_cmd.step.dependOn(b.getInstallStep());
    swarm_cmd.stdio = .inherit;
    b.step("run-swarm", "Boot a 2-host simulated swarm cluster in QEMU")
        .dependOn(&swarm_cmd.step);

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

    var qemu_tpm_args = ArrayList([]const u8).empty;
    defer qemu_tpm_args.deinit(b.allocator);
    try qemu_tpm_args.appendSlice(b.allocator, qemu_args.items);
    try appendUsbKeyArgs(b, &qemu_tpm_args, cfg.qemu_usb_key_opt);
    try appendTpmArgs(b, &qemu_tpm_args);
    if (cfg.qemu_extra_opt) |extra| {
        var it = std.mem.tokenizeScalar(u8, extra, ' ');
        while (it.next()) |tok| try qemu_tpm_args.append(b.allocator, tok);
    }
    try appendBootArgs(b, &qemu_tpm_args, "diosix.mode=dev");
    qemu.add(
        &create_storage_cmd.step,
        &setup_tpm_cmd.step,
        "run-tpm",
        "Run the hypervisor with virtual TPM 2.0 (swtpm)",
        qemu_tpm_args.items,
    );

    const pt_disk_path = "zig-out/personal-pt-disk.img";
    const mk_pt_disk = b.addSystemCommand(&.{
        "truncate", "-s", "16M", pt_disk_path,
    });
    var qemu_personal_args = ArrayList([]const u8).empty;
    defer qemu_personal_args.deinit(b.allocator);
    for (qemu_args.items) |arg| {
        const rep = if (std.mem.eql(u8, arg, cfg.mem_size)) "2G" else arg;
        try qemu_personal_args.append(b.allocator, rep);
    }
    try qemu_personal_args.appendSlice(b.allocator, &.{
        "-drive",  "file=" ++ pt_disk_path ++ ",if=none,format=raw,id=ptdisk",
        "-device", "virtio-blk-pci,drive=ptdisk,disable-legacy=on",
    });
    try appendBootArgs(b, &qemu_personal_args, "diosix.mode=dev");
    qemu.add(
        &mk_pt_disk.step,
        &create_storage_cmd.step,
        "run-personal",
        "Run Personal edition with a PCIe VirtIO block passthrough device",
        qemu_personal_args.items,
    );
}

test {
    std.testing.refAllDecls(@This());
}
