// Diosix Hypervisor Guest Management CLI — VM Spawn (dsx run).
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const api = @import("../api.zig");
const manifest = @import("../manifest.zig");
const common = @import("../common.zig");
const loader = @import("../loader.zig");
const net = @import("../net.zig");
const vm_stage = @import("stage.zig");
const fdt_patch = @import("fdt_patch.zig");
const owned = @import("owned.zig");

const MAX_PATH_LEN = common.MAX_PATH_LEN;
const MAX_ELF_FILE_SIZE = common.MAX_ELF_FILE_SIZE;
const MAX_MANIFEST_SIZE = common.MAX_MANIFEST_SIZE;
const PAGE_SIZE_KB = common.PAGE_SIZE_KB;
const KB_PER_MB = common.KB_PER_MB;
pub const MIB_SHIFT: u6 = 20;

const OwnedStrings = owned.OwnedStrings;
const OOM_MSG = owned.OOM_MSG;

const printStr = common.printStr;
const isArch = common.isArch;
const printApiError = common.printApiError;
const parseMemorySizeMb = common.parseMemorySizeMb;
const readBinaryFile = common.readBinaryFile;
const unmapBinaryFile = common.unmapBinaryFile;
const loadRuntimeSystemConfig = common.loadRuntimeSystemConfig;
const saveGuestRegistry = common.saveGuestRegistry;

const RunOption = enum {
    @"--name",
    @"-n",
    @"--domain",
    @"--manifest",
    @"-m",
    @"--vcpus",
    @"--ram",
    @"--pcpu",
    @"--pcpu-quota",
    @"--ram-quota",
    @"--disk",
    @"-d",
    @"--cdrom",
    @"--iso",
    @"--media",
    @"--ip",
    @"--trusted",
    @"--untrusted",
    @"--steward",
    @"--standby-root",
    @"--confidential",
    @"--dtb",
    @"--arch",
    @"-a",
    @"--net",
    @"--net-via",
    @"--user",
};

fn takeOpt(
    args: []const [*:0]const u8,
    idx: *usize,
    flag: []const u8,
) ?[]const u8 {
    if (idx.* + 1 >= args.len) {
        common.printFmt("Error: Option '{s}' requires a value.\n", .{flag});
        return null;
    }
    idx.* += 1;
    return std.mem.span(args[idx.*]);
}

pub fn cmdRun(client: *api.DiosixClient, args: []const [*:0]const u8) !void {
    const exe_name = common.getExeName();
    const allocator = std.heap.page_allocator;
    if (args.len == 0) {
        common.printFmt(
            \\Usage: {s} run <image|name> [--name <name>] [--vcpus <N>]
            \\       [--ram <size>] [--pcpu <1-90>] [--ram-quota <size>]
            \\       [--disk <disk>] [--cdrom <iso>] [--ip <ip>]
            \\       [--net <none|local|wan|router>] [--net-via <vm|cid>]
            \\       [--manifest <path>] [--domain <domain>] [--trusted]
            \\       [--arch <arch>]
            \\
        , .{exe_name});
        return;
    }

    const sys_cfg = loadRuntimeSystemConfig();
    var elf_path: ?[]const u8 = null;
    var vm_name: ?[]const u8 = null;
    var domain_name: ?[]const u8 = null;
    var manifest_path: ?[]const u8 = null;
    var vcpus: usize = sys_cfg.default_vcpus;
    var ram_str: []const u8 = sys_cfg.defaultRam();
    var pcpu_pct: usize = 0;
    var ram_quota_str: ?[]const u8 = null;
    var disk_str: ?[]const u8 = null;
    var cdrom_str: ?[]const u8 = null;
    var ip_str: []const u8 = "";
    var trusted: bool = false;
    var is_steward: bool = false;
    var is_standby_root: bool = false;
    var is_confidential: bool = false;
    var arch_str: []const u8 = sys_cfg.defaultArch();
    var dtb_path: ?[]const u8 = null;
    var net_mode: ?net.NetMode = null;
    var net_via_str: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const span = std.mem.span(args[i]);
        if (std.meta.stringToEnum(RunOption, span)) |opt| {
            switch (opt) {
                .@"--name", .@"-n" => {
                    vm_name = takeOpt(args, &i, "--name") orelse return;
                },
                .@"--domain" => {
                    domain_name = takeOpt(args, &i, "--domain") orelse return;
                },
                .@"--manifest", .@"-m" => {
                    manifest_path =
                        takeOpt(args, &i, "--manifest") orelse return;
                },
                .@"--vcpus" => {
                    const v_str = takeOpt(args, &i, "--vcpus") orelse return;
                    vcpus = std.fmt.parseInt(usize, v_str, 10) catch {
                        return printStr("Error: Invalid '--vcpus' value.\n");
                    };
                    if (vcpus == 0 or vcpus > api.MAX_GUEST_VCPUS) {
                        return printStr(
                            "Error: '--vcpus' must be between 1 and 4096.\n",
                        );
                    }
                },
                .@"--ram" => ram_str = takeOpt(args, &i, "--ram") orelse return,
                .@"--pcpu", .@"--pcpu-quota" => {
                    const p_str = takeOpt(args, &i, "--pcpu") orelse return;
                    const trimmed = std.mem.trimEnd(u8, p_str, "%");
                    pcpu_pct = std.fmt.parseInt(usize, trimmed, 10) catch {
                        return printStr("Error: Invalid '--pcpu' value.\n");
                    };
                    if (pcpu_pct == 0 or
                        pcpu_pct > api.MAX_CHILD_PCPU_QUOTA_PCT)
                    {
                        return printStr(
                            "Error: '--pcpu' must be between 1 and 90%.\n",
                        );
                    }
                },
                .@"--ram-quota" => {
                    ram_quota_str =
                        takeOpt(args, &i, "--ram-quota") orelse return;
                },
                .@"--disk", .@"-d" => {
                    disk_str = takeOpt(args, &i, "--disk") orelse return;
                },
                .@"--cdrom", .@"--iso", .@"--media" => {
                    cdrom_str = takeOpt(args, &i, "--cdrom") orelse return;
                },
                .@"--ip" => ip_str = takeOpt(args, &i, "--ip") orelse return,
                .@"--trusted" => trusted = true,
                .@"--untrusted" => trusted = false,
                .@"--steward" => is_steward = true,
                .@"--standby-root" => is_standby_root = true,
                .@"--confidential" => is_confidential = true,
                .@"--dtb" => {
                    dtb_path = takeOpt(args, &i, "--dtb") orelse return;
                },
                .@"--arch", .@"-a" => {
                    arch_str = takeOpt(args, &i, "--arch") orelse return;
                },
                .@"--net" => {
                    const m_str = takeOpt(args, &i, "--net") orelse return;
                    net_mode = net.parseNetMode(m_str) orelse {
                        return common.printFmt(
                            "Error: Invalid '--net' mode '{s}'.\n",
                            .{m_str},
                        );
                    };
                },
                .@"--net-via" => {
                    net_via_str = takeOpt(args, &i, "--net-via") orelse return;
                },
                .@"--user" => return printStr(
                    "Error: Unrecognized option '--user'. " ++
                        "To specify a VM name, use '--name <name>'.\n",
                ),
            }
        } else if (isArch(span)) {
            arch_str = span;
        } else if (std.mem.startsWith(u8, span, "-")) {
            return common.printFmt(
                "Error: Unknown option '{s}'. Use '{s} run' for usage.\n",
                .{ span, exe_name },
            );
        } else if (elf_path == null) {
            elf_path = span;
        }
    }

    // Owned copies so domain manifest fields outlive unmapping.
    var domain_strings = OwnedStrings.init(allocator);
    defer domain_strings.deinit();

    if (domain_name) |dname| {
        if (vm_name == null) vm_name = dname;
        const m_file = manifest_path orelse sys_cfg.systemManifestPath();
        if (readBinaryFile(m_file, MAX_MANIFEST_SIZE)) |m_content| {
            defer unmapBinaryFile(m_content);
            if (manifest.parseSystemManifest(allocator, m_content)) |sys_m_v| {
                var sys_m = sys_m_v;
                defer sys_m.deinit();
                if (sys_m.domains.get(dname)) |dom| {
                    vm_stage.copyDomainFields(
                        &domain_strings,
                        dom,
                        &elf_path,
                        &ram_str,
                        &disk_str,
                        &cdrom_str,
                        &ip_str,
                    ) catch return printStr(OOM_MSG);
                    if (dom.vcpus > 0 and vcpus == 1) vcpus = dom.vcpus;
                    if (net_mode == null) {
                        net_mode = net.inferDomainNetMode(dom);
                    }
                }
            } else |_| {}
        } else |_| {}
    }

    if (elf_path) |ep| {
        if (std.mem.endsWith(u8, ep, ".iso")) {
            if (cdrom_str == null) cdrom_str = ep;
            if (vm_name == null) {
                const base = if (std.mem.lastIndexOfScalar(u8, ep, '/')) |s|
                    ep[s + 1 ..]
                else
                    ep;
                vm_name = if (base.len > 4) base[0 .. base.len - 4] else base;
            }
            elf_path = "guest-shim";
        }
    } else if (cdrom_str != null) {
        elf_path = "guest-shim";
    }

    if (elf_path == null) {
        return common.printFmt(
            "Error: No ELF binary specified. Use '{s} run <image>' " ++
                "or specify --manifest and --domain.\n",
            .{exe_name},
        );
    }
    if (vm_name == null) {
        const ep = elf_path.?;
        vm_name = if (std.mem.lastIndexOfScalar(u8, ep, '/')) |slash|
            ep[slash + 1 ..]
        else
            ep;
    }

    common.printFmt("[10%] Resolving guest image '{s}'...\n", .{elf_path.?});
    const elf_found = vm_stage.resolveElfImage(elf_path.?) catch {
        return printStr(OOM_MSG);
    };
    const elf_data = elf_found orelse {
        return common.printFmt(
            "Error: Guest ELF binary '{s}' not found (checked current dir, " ++
                "{s}/).\n",
            .{ elf_path.?, sys_cfg.imagesDir() },
        );
    };
    defer unmapBinaryFile(elf_data);

    const dtb_data = fdt_patch.loadHostOrCustomDtb(dtb_path);
    defer unmapBinaryFile(dtb_data);

    var final_disk_buf: [MAX_PATH_LEN]u8 = undefined;
    const final_disk = vm_stage.resolveRunDisk(
        disk_str,
        vm_name.?,
        &final_disk_buf,
    ) catch |err| {
        switch (err) {
            error.PathTooLong => {
                printStr("Error: Virtual disk path is too long.\n");
            },
            error.OutOfMemory => printStr(OOM_MSG),
        }
        return;
    };

    var final_cdrom: []const u8 = "";
    var joined_cdrom: ?[]u8 = null;
    defer if (joined_cdrom) |owned_path| allocator.free(owned_path);
    if (cdrom_str) |c| {
        if (std.mem.startsWith(u8, c, "/")) {
            final_cdrom = c;
        } else {
            const has_media_ext = std.mem.endsWith(u8, c, ".iso") or
                std.mem.endsWith(u8, c, ".raw");
            const ext: []const u8 = if (has_media_ext) "" else ".iso";
            const joined = allocator.print(
                "{s}/{s}{s}",
                .{ sys_cfg.isoDir(), c, ext },
            ) catch {
                printStr(OOM_MSG);
                return;
            };
            joined_cdrom = joined;
            final_cdrom = joined;
        }
    }

    var shim_payload_data: []u8 = &[_]u8{};
    const payload_path = if (final_cdrom.len > 0) final_cdrom else final_disk;
    if (payload_path.len > 0) {
        if (readBinaryFile(payload_path, MAX_ELF_FILE_SIZE)) |cd_data| {
            shim_payload_data = cd_data;
        } else |_| {}
    }
    defer unmapBinaryFile(shim_payload_data);

    const req_arch =
        std.meta.stringToEnum(api.TargetArch, arch_str) orelse .riscv64;
    const arch_enum = loader.checkGuestArch(elf_data, req_arch) orelse {
        if (!@import("builtin").is_test) std.process.exit(1);
        return;
    };
    const ram_mb = parseMemorySizeMb(ram_str);
    const raw_quota_mb = if (ram_quota_str) |rq|
        parseMemorySizeMb(rq)
    else
        ram_mb;
    const ram_quota_mb = @max(ram_mb, raw_quota_mb);
    const eff_pcpu = vm_stage.checkChildResourceQuota(
        client,
        vm_name.?,
        vcpus,
        ram_mb,
        pcpu_pct,
        ram_quota_mb,
    ) orelse {
        if (!@import("builtin").is_test) std.process.exit(1);
        return;
    };
    const final_ram_str = allocator.print("{d} MB", .{ram_mb}) catch {
        printStr(OOM_MSG);
        return;
    };
    defer allocator.free(final_ram_str);
    const eff_net_mode = net_mode orelse .local;
    const upstream_cid: usize = if (net_via_str) |vs|
        net.resolveUpstreamCid(vs) orelse {
            common.printFmt(
                "Error: Unknown upstream router VM '{s}'.\n",
                .{vs},
            );
            return;
        }
    else
        0;

    var run_flags: usize = if (trusted) api.RunFlags.TRUSTED else 0;
    if (is_steward) run_flags |= api.RunFlags.STEWARD;
    if (is_standby_root) run_flags |= api.RunFlags.STANDBY_ROOT;
    if (is_confidential) run_flags |= api.RunFlags.CONFIDENTIAL;
    if (eff_net_mode == .none) run_flags |= api.RunFlags.NET_ISOLATED;
    if (upstream_cid > 0) {
        run_flags |= (upstream_cid & api.RunFlags.NET_UPSTREAM_MASK) <<
            api.RunFlags.NET_UPSTREAM_SHIFT;
    }
    const child_cid = client.run(
        0,
        &[_]u8{},
        &[_]u8{},
        @backingInt(arch_enum),
        run_flags,
    ) catch |err| {
        printApiError("Create child VM", err);
        if (!@import("builtin").is_test) std.process.exit(1);
        return;
    };

    const ram_pages = (ram_mb * KB_PER_MB) / PAGE_SIZE_KB;
    const ram_quota_pages = (ram_quota_mb * KB_PER_MB) / PAGE_SIZE_KB;
    client.setQuotaWithPcpu(
        child_cid,
        ram_quota_pages,
        vcpus,
        0,
        0,
        eff_pcpu,
        ram_pages,
    ) catch |err| {
        printApiError("Configure child VM quota", err);
        _ = client.terminate(child_cid, 1) catch {};
        if (!@import("builtin").is_test) std.process.exit(1);
        return;
    };

    const default_ip: ?[]u8 = if (ip_str.len > 0)
        null
    else
        allocator.print(
            "{s}{d}",
            .{ sys_cfg.subnetPrefix(), child_cid },
        ) catch {
            printStr(OOM_MSG);
            _ = client.terminate(child_cid, 1) catch {};
            return;
        };
    defer if (default_ip) |ip| allocator.free(ip);
    const final_ip: []const u8 = default_ip orelse ip_str;

    vm_stage.stageChildVmManifest(
        allocator,
        client,
        child_cid,
        vm_name.?,
        domain_name,
        manifest_path,
    );
    net.applyVmNetConfig(
        allocator,
        client,
        child_cid,
        final_ip,
        eff_net_mode,
        upstream_cid,
    );

    const base_gpa: usize = switch (arch_enum) {
        .x86_64 => 0,
        .aarch64 => 0x40000000,
        .riscv64, .riscv32 => 0xe0000000,
    };
    _ = loader.loadElfViaForeignMapping(
        client,
        child_cid,
        elf_data,
        dtb_data,
        shim_payload_data,
        base_gpa,
        ram_mb << MIB_SHIFT,
        vcpus,
    ) catch |err| {
        printApiError("Load guest ELF", err);
        _ = client.terminate(child_cid, 1) catch {};
        if (!@import("builtin").is_test) std.process.exit(1);
        return;
    };

    const raw_img = elf_path.?;
    const img_name = if (std.mem.lastIndexOfScalar(u8, raw_img, '/')) |slash|
        raw_img[slash + 1 ..]
    else
        raw_img;

    saveGuestRegistry(
        child_cid,
        vm_name.?,
        img_name,
        vcpus,
        final_ram_str,
        final_disk,
        final_cdrom,
        final_ip,
        if (trusted) "trusted" else "untrusted",
        "running",
    );

    vm_stage.printRunSuccess(
        vm_name.?,
        child_cid,
        vcpus,
        final_ram_str,
        final_disk,
        final_cdrom,
        final_ip,
    );
}

test "vm_run: RunOption enum parses expected CLI flags" {
    std.testing.refAllDecls(@This());
    _ = vm_stage;
    _ = fdt_patch;
    _ = owned;
    try std.testing.expectEqual(
        RunOption.@"--domain",
        std.meta.stringToEnum(RunOption, "--domain").?,
    );
}
