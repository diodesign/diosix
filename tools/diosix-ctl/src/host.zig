// Diosix Hypervisor Guest Management CLI — Host & Bare-Metal Installer.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const api = @import("api.zig");
const installer = @import("installer.zig");
const common = @import("common.zig");
const sysconfig = @import("sysconfig.zig");
const gui_cmd = @import("gui.zig");
const host_info = @import("host/info.zig");
const linux = std.os.linux;

pub const cmdGui = gui_cmd.cmdGui;
pub const cmdTour = gui_cmd.cmdTour;

pub const MAX_VERSION_STR_LEN = host_info.MAX_VERSION_STR_LEN;
pub const formatVersionChannel = host_info.formatVersionChannel;
pub const extractBuildBranch = host_info.extractBuildBranch;
pub const allocHostInfo = host_info.allocHostInfo;
pub const formatHostInfo = host_info.formatHostInfo;

const CID_SELF = common.CID_SELF;
const printStr = common.printStr;
const printApiError = common.printApiError;
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

const JsonFlag = common.JsonFlag;

pub fn cmdHost(client: *api.DiosixClient, args: []const [*:0]const u8) !void {
    const exe_name = common.getExeName();
    if (args.len == 0) {
        common.printFmt(
            "Usage: {s} host <info|install|reboot|poweroff|shutdown> " ++
                "[--json]\n",
            .{exe_name},
        );
        return;
    }
    const subcmd = std.mem.span(args[0]);
    var json_mode = false;
    for (args[1..]) |arg| {
        if (common.isJsonFlag(std.mem.span(arg))) {
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
        common.printFmt(
            "Unknown host subcommand '{s}'. " ++
                "Use '{s} host <info|install|reboot|poweroff>'.\n",
            .{ subcmd, exe_name },
        );
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

/// Largest installer configuration file read by `host install`.
const MAX_INSTALL_CONFIG_BYTES: usize = 64 * 1024;

pub fn cmdHostInfo(client: *api.DiosixClient, json_mode: bool) !void {
    const info = client.getHypervisorInfo() catch |err| {
        printApiError("Query host hypervisor info", err);
        return;
    };

    const allocator = std.heap.page_allocator;
    const out = try allocHostInfo(allocator, info, json_mode);
    defer allocator.free(out);
    printStr(out);
}

pub fn cmdHostInstall(args: []const [*:0]const u8) !void {
    const exe_name = common.getExeName();
    const allocator = std.heap.page_allocator;
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
                    common.printFmt(
                        \\Usage: {s} host install [--mode basic|expert]
                        \\  [--disk <dev>] [--config <diosix-install.toml>]
                        \\  [--stewards] [--standby-root] [--dry-run] [--json]
                        \\
                    , .{exe_name});
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
        if (readBinaryFile(cfg_path, MAX_INSTALL_CONFIG_BYTES)) |cbytes| {
            cfg_mapped = cbytes;
            plan = installer.parseInstallConfigToml(cbytes);
            plan.dry_run = dry_run;
            loaded_config_file = true;
        } else |_| {
            printStr("Error: Could not read installer configuration file.\n");
            return;
        }
    } else if (readBinaryFile(
        sys_cfg.installConfigPath(),
        MAX_INSTALL_CONFIG_BYTES,
    )) |def_bytes| {
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
        std.mem.eql(u8, plan.target_disk, sysconfig.DEFAULT_TARGET_DISK))
    {
        for (sysconfig.CANDIDATE_HOST_DISKS) |cand| {
            var z_buf: [common.MAX_PATH_LEN]u8 = undefined;
            if (common.toPathZ(cand, &z_buf)) |cz| {
                if (fileExistsPath(cz.ptr)) {
                    plan.target_disk = cand;
                    break;
                }
            }
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
        _ = linux.mkdir(sysconfig.VAR_LIB_DIOSIX_DIR, 0o755);
        const rec_toml = try installer.allocInstallReceiptToml(allocator, plan);
        defer allocator.free(rec_toml);
        if (rec_toml.len > 0) {
            try writeFile(installer.INSTALL_RECEIPT_PATH, rec_toml);
        }
    }

    const out = try installer.allocInstallPlanOutput(
        allocator,
        plan,
        json_mode,
    );
    defer allocator.free(out);
    if (out.len > 0) printStr(out);
}

test "host: submodules are wired in" {
    std.testing.refAllDecls(@This());
    _ = gui_cmd;
    _ = host_info;
}
