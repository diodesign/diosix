// Diosix Hypervisor Guest Management CLI — Host & Bare-Metal Installer.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const api = @import("api.zig");
const installer = @import("installer.zig");
const common = @import("common.zig");
const gui_cmd = @import("gui.zig");
const linux = std.os.linux;

pub const cmdGui = gui_cmd.cmdGui;
pub const cmdTour = gui_cmd.cmdTour;

const CID_SELF = common.CID_SELF;
const KB_PER_MB = common.KB_PER_MB;
const printStr = common.printStr;
const printApiError = common.printApiError;
const sanitizeJsonStr = common.sanitizeJsonStr;
const readBinaryFile = common.readBinaryFile;
const unmapBinaryFile = common.unmapBinaryFile;
const writeFile = common.writeFile;
const fileExistsPath = common.fileExistsPath;
const detectSeatProfile = common.detectSeatProfile;
const loadRuntimeSystemConfig = common.loadRuntimeSystemConfig;

const HostSubcommand = enum {
    info,
    install,
    reboot,
    poweroff,
    shutdown,
};

const HostInstallOption = enum {
    @"--mode",
    @"-m",
    @"--disk",
    @"-d",
    @"--config",
    @"-c",
    @"--hostname",
    @"--stewards",
    @"--standby-root",
    @"--dry-run",
    @"--json",
    @"-j",
    @"--help",
    @"-h",
};

const JsonFlag = enum {
    @"--json",
    @"-j",
};

pub fn cmdHost(client: *api.DiosixClient, args: []const [*:0]const u8) !void {
    const exe_name = common.getExeName();
    if (args.len == 0) {
        var buf: [160]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &buf,
            "Usage: {s} host <info|install|reboot|poweroff|shutdown> " ++
                "[--json]\n",
            .{exe_name},
        ) catch return;
        printStr(msg);
        return;
    }
    const subcmd = std.mem.span(args[0]);
    var json_mode = false;
    for (args[1..]) |arg| {
        const span = std.mem.span(arg);
        if (std.meta.stringToEnum(JsonFlag, span) != null) {
            json_mode = true;
        }
    }
    if (std.meta.stringToEnum(HostSubcommand, subcmd)) |cmd| {
        switch (cmd) {
            .info => try cmdHostInfo(client, json_mode),
            .install => try cmdHostInstall(args[1..]),
            .reboot => try cmdReboot(client),
            .poweroff, .shutdown => try cmdPoweroff(client),
        }
    } else {
        var buf: [160]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &buf,
            "Unknown host subcommand '{s}'. " ++
                "Use '{s} host <info|install|reboot|poweroff>'.\n",
            .{ subcmd, exe_name },
        ) catch return;
        printStr(msg);
    }
}

pub fn cmdPoweroff(client: *api.DiosixClient) !void {
    if (client.getInfo(1)) |info| {
        if (info.is_root == 0) {
            printStr("Command 'poweroff' is only available on the Root VM.\n");
            return;
        }
    } else |err| {
        printApiError("Query VM info", err);
        return;
    }
    printStr("Powering off host...\n");
    client.terminate(CID_SELF, 0) catch |err| {
        printApiError("Poweroff", err);
        return;
    };
}

pub fn cmdReboot(client: *api.DiosixClient) !void {
    if (client.getInfo(1)) |info| {
        if (info.is_root == 0) {
            printStr("Command 'reboot' is only available on the Root VM.\n");
            return;
        }
    } else |err| {
        printApiError("Query VM info", err);
        return;
    }
    client.terminate(CID_SELF, 1) catch |err| {
        printApiError("Reboot", err);
        return;
    };
}

pub fn formatVersionChannel(
    buf: []u8,
    major: u16,
    minor: u16,
    patch: u16,
) []const u8 {
    if (patch > 0) {
        return std.fmt.bufPrint(
            buf,
            "{d}.{d}.{d}",
            .{ major, minor, patch },
        ) catch "0.0";
    }
    return std.fmt.bufPrint(buf, "{d}.{d}", .{ major, minor }) catch "0.0";
}

/// Extracts the git branch from a hypervisor `build_desc` string
/// (e.g., `"Version 26.1 (beta) main/6f19e11 ..."` -> `"main"`).
pub fn extractBuildBranch(build_desc: []const u8) []const u8 {
    var tok_it = std.mem.tokenizeScalar(u8, build_desc, ' ');
    _ = tok_it.next() orelse return ""; // Skip "Version".
    _ = tok_it.next() orelse return ""; // Skip version number.
    var tok = tok_it.next() orelse return "";
    if (tok.len > 0 and tok[0] == '(') {
        tok = tok_it.next() orelse return ""; // Skip "(channel)".
    }
    if (std.mem.lastIndexOfScalar(u8, tok, '/')) |slash| {
        if (slash > 0) return tok[0..slash];
    }
    return "";
}

pub fn formatHostInfo(
    buf: []u8,
    info: api.HypervisorInfo,
    json_mode: bool,
) []const u8 {
    var ver_buf: [32]u8 = undefined;
    const ver_str = formatVersionChannel(
        &ver_buf,
        info.version_major,
        info.version_minor,
        info.version_patch,
    );
    const channel_str = if ((info.version_minor % 2) == 0) "stable" else "beta";
    const raw_commit = std.mem.sliceTo(&info.build_commit, 0);
    const raw_isa = std.mem.sliceTo(&info.host_cpu_isa, 0);
    const raw_build = std.mem.sliceTo(&info.build_desc, 0);
    const raw_branch = extractBuildBranch(raw_build);

    var branch_buf: [64]u8 = undefined;
    var commit_buf: [api.BUILD_COMMIT_LEN]u8 = undefined;
    var isa_buf: [api.HOST_CPU_ISA_LEN]u8 = undefined;
    const branch_str = sanitizeJsonStr(&branch_buf, raw_branch);
    const commit_str = sanitizeJsonStr(&commit_buf, raw_commit);
    const isa_str = sanitizeJsonStr(&isa_buf, raw_isa);

    const feat = info.features;
    const HvFeat = api.HypervisorFeature;

    if (json_mode) {
        const charter_sealed =
            if ((feat & HvFeat.CHARTER_SEALED) != 0) "true" else "false";
        const json_fmt =
            "{{\"version\":\"{s}\",\"version_major\":{d}," ++
            "\"version_minor\":{d},\"version_patch\":{d}," ++
            "\"channel\":\"{s}\",\"branch\":\"{s}\",\"commit\":\"{s}\"," ++
            "\"abi\":\"{d}.{d}.{d}\",\"cores\":{d},\"isa\":\"{s}\"," ++
            "\"total_ram_kb\":{d},\"free_ram_kb\":{d}," ++
            "\"hv_reserved_bytes\":{d},\"hv_heap_free_bytes\":{d}," ++
            "\"features\":{d},\"charter_sealed\":{s}}}\n";
        return std.fmt.bufPrint(buf, json_fmt, .{
            ver_str,
            info.version_major,
            info.version_minor,
            info.version_patch,
            channel_str,
            if (branch_str.len > 0) branch_str else "unknown",
            if (commit_str.len > 0) commit_str else "release",
            info.abi_version_major,
            info.abi_version_minor,
            info.abi_version_patch,
            info.host_physical_cores,
            isa_str,
            info.host_total_ram_kb,
            info.host_free_ram_kb,
            info.hv_reserved_bytes,
            info.hv_heap_free_bytes,
            info.features,
            charter_sealed,
        }) catch "";
    }

    const hw_mark: u8 = if ((feat & HvFeat.HARDWARE_VIRT) != 0) 'x' else ' ';
    const s2_mark: u8 = if ((feat & HvFeat.STAGE2_PAGING) != 0) 'x' else ' ';
    const dy_mark: u8 = if ((feat & HvFeat.DYNAREC) != 0) 'x' else ' ';
    const vs_mark: u8 = if ((feat & HvFeat.VIRTIO_VSOCK) != 0) 'x' else ' ';
    const cs_mark: u8 = if ((feat & HvFeat.CHARTER_SEALED) != 0) 'x' else ' ';

    return std.fmt.bufPrint(buf,
        \\Hypervisor build : {s}
        \\Footprint        : {d} KB reserved, {d} KB free
        \\ABI version      : {d}.{d}.{d}
        \\Host cores       : {d} physical hart(s) {s}
        \\Host RAM         : {d} MB total / {d} MB free
        \\Timer frequency  : {d} Hz
        \\Capabilities     :
        \\  [{c}] Hardware H-extension (nested virtualization)
        \\  [{c}] Stage-2 Sv39x4 paging
        \\  [{c}] Cross-arch JIT dynamic recompilation
        \\  [{c}] VirtIO-vsock (AF_VSOCK in-hypervisor networking)
        \\  [{c}] Constitutional Charter sealed in M-mode
        \\
    , .{
        if (raw_build.len > 0) raw_build else "n/a",
        info.hv_reserved_bytes / 1024,
        info.hv_heap_free_bytes / 1024,
        info.abi_version_major,
        info.abi_version_minor,
        info.abi_version_patch,
        info.host_physical_cores,
        if (isa_str.len > 0) isa_str else "",
        info.host_total_ram_kb / KB_PER_MB,
        info.host_free_ram_kb / KB_PER_MB,
        info.host_timer_freq_hz,
        hw_mark,
        s2_mark,
        dy_mark,
        vs_mark,
        cs_mark,
    }) catch "";
}

pub fn cmdHostInfo(client: *api.DiosixClient, json_mode: bool) !void {
    const info = client.getHypervisorInfo() catch |err| {
        printApiError("Query host hypervisor info", err);
        return;
    };

    var buf: [1024]u8 = undefined;
    const out = formatHostInfo(&buf, info, json_mode);
    if (out.len > 0) {
        printStr(out);
    }
}

pub fn cmdHostInstall(args: []const [*:0]const u8) !void {
    const exe_name = common.getExeName();
    var mode_opt: installer.InstallMode = .basic;
    var disk_opt: ?[]const u8 = null;
    var config_opt: ?[]const u8 = null;
    var hostname_opt: ?[]const u8 = null;
    var enable_stewards = false;
    var standby_root = false;
    var dry_run = false;
    var json_mode = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const span = std.mem.span(args[i]);
        if (std.meta.stringToEnum(HostInstallOption, span)) |opt| {
            switch (opt) {
                .@"--mode", .@"-m" => {
                    if (i + 1 >= args.len) {
                        printStr(
                            "Error: Option '--mode' requires " ++
                                "'basic' or 'expert'.\n",
                        );
                        return;
                    }
                    i += 1;
                    const m_str = std.mem.span(args[i]);
                    mode_opt = installer.InstallMode.fromStr(m_str) orelse {
                        printStr(
                            "Error: Invalid installer mode. " ++
                                "Use '--mode basic' or '--mode expert'.\n",
                        );
                        return;
                    };
                },
                .@"--disk", .@"-d" => {
                    if (i + 1 >= args.len) {
                        printStr(
                            "Error: Option '--disk' requires a block " ++
                                "device path (e.g. /dev/nvme0n1).\n",
                        );
                        return;
                    }
                    i += 1;
                    disk_opt = std.mem.span(args[i]);
                },
                .@"--config", .@"-c" => {
                    if (i + 1 >= args.len) {
                        printStr(
                            "Error: Option '--config' requires a path " ++
                                "to diosix-install.toml.\n",
                        );
                        return;
                    }
                    i += 1;
                    config_opt = std.mem.span(args[i]);
                    mode_opt = .expert;
                },
                .@"--hostname" => {
                    if (i + 1 >= args.len) {
                        printStr(
                            "Error: Option '--hostname' requires " ++
                                "a hostname string.\n",
                        );
                        return;
                    }
                    i += 1;
                    hostname_opt = std.mem.span(args[i]);
                },
                .@"--stewards" => enable_stewards = true,
                .@"--standby-root" => standby_root = true,
                .@"--dry-run" => dry_run = true,
                .@"--json", .@"-j" => json_mode = true,
                .@"--help", .@"-h" => {
                    var hbuf: [512]u8 = undefined;
                    const hmsg = std.fmt.bufPrint(&hbuf,
                        \\Usage: {s} host install [--mode basic|expert]
                        \\  [--disk <dev>] [--config <diosix-install.toml>]
                        \\  [--stewards] [--standby-root] [--dry-run] [--json]
                        \\
                    , .{exe_name}) catch return;
                    printStr(hmsg);
                    return;
                },
            }
        }
    }

    const sys_cfg = loadRuntimeSystemConfig();
    var cfg_mapped: ?[]u8 = null;
    defer if (cfg_mapped) |m| unmapBinaryFile(m);
    var loaded_config_file = false;
    var plan = installer.InstallPlan{
        .mode = mode_opt,
        .seat_profile = detectSeatProfile(),
        .enable_stewards = enable_stewards,
        .standby_root_vm = standby_root,
        .dry_run = dry_run,
    };

    if (config_opt) |cfg_path| {
        if (readBinaryFile(cfg_path, 65536)) |cbytes| {
            cfg_mapped = cbytes;
            plan = installer.parseInstallConfigToml(cbytes);
            plan.dry_run = dry_run;
            loaded_config_file = true;
        } else |_| {
            printStr("Error: Could not read installer configuration file.\n");
            return;
        }
    } else if (readBinaryFile(sys_cfg.installConfigPath(), 65536)) |def_bytes| {
        cfg_mapped = def_bytes;
        plan = installer.parseInstallConfigToml(def_bytes);
        plan.mode = mode_opt;
        if (enable_stewards) plan.enable_stewards = true;
        if (standby_root) plan.standby_root_vm = true;
        plan.dry_run = dry_run;
        loaded_config_file = true;
    } else |_| {}

    if (disk_opt) |d| {
        if (!installer.isValidBlockDevicePath(d)) {
            printStr(
                "Error: Invalid target disk path (must be /dev/<disk>, " ++
                    "/tmp/<img>, or /var/lib/diosix/<img>).\n",
            );
            return;
        }
        plan.target_disk = d;
    } else if (!loaded_config_file or
        std.mem.eql(u8, plan.target_disk, "/dev/vda"))
    {
        if (fileExistsPath("/dev/nvme0n1")) {
            plan.target_disk = "/dev/nvme0n1";
        } else if (fileExistsPath("/dev/vda")) {
            plan.target_disk = "/dev/vda";
        } else if (fileExistsPath("/dev/sda")) {
            plan.target_disk = "/dev/sda";
        } else if (fileExistsPath("/dev/mmcblk0")) {
            plan.target_disk = "/dev/mmcblk0";
        }
    }

    if (hostname_opt) |hn| {
        if (!installer.isValidHostname(hn)) {
            printStr(
                "Error: Invalid hostname (must be 1..64 RFC-1123 " ++
                    "alphanumeric/hyphen characters).\n",
            );
            return;
        }
        plan.hostname = hn;
    }

    if (!plan.dry_run) {
        _ = linux.mkdir("/var/lib/diosix", 0o755);
        var rec_buf: [512]u8 = undefined;
        const rec_toml = installer.formatInstallReceiptToml(&rec_buf, plan);
        if (rec_toml.len > 0) {
            writeFile(installer.INSTALL_RECEIPT_PATH, rec_toml) catch {};
        }
    }

    var out_buf: [1024]u8 = undefined;
    const out = installer.formatInstallPlanOutput(&out_buf, plan, json_mode);
    if (out.len > 0) printStr(out);
}

test "host: formatVersionChannel formats CalVer strings" {
    std.testing.refAllDecls(@This());
    _ = gui_cmd;
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings(
        "26.1",
        formatVersionChannel(&buf, 26, 1, 0),
    );
    try std.testing.expectEqualStrings(
        "26.2.1",
        formatVersionChannel(&buf, 26, 2, 1),
    );
}
