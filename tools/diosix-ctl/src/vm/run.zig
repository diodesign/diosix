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
const fdt_guest = @import("fdt_guest.zig");
const sysconfig = @import("../sysconfig.zig");
const owned = @import("owned.zig");
const run_opts = @import("run_opts.zig");

const MAX_PATH_LEN = common.MAX_PATH_LEN;
const MAX_ELF_FILE_SIZE = common.MAX_ELF_FILE_SIZE;
const MAX_MEDIA_FILE_SIZE = common.MAX_MEDIA_FILE_SIZE;
const MAX_MANIFEST_SIZE = common.MAX_MANIFEST_SIZE;
const PAGE_SIZE_KB = common.PAGE_SIZE_KB;
const KB_PER_MB = common.KB_PER_MB;
pub const MIB_SHIFT: u6 = 20;

const OwnedStrings = owned.OwnedStrings;
const OOM_MSG = owned.OOM_MSG;

const printStr = common.printStr;
const printApiError = common.printApiError;
const parseMemorySizeMb = common.parseMemorySizeMb;
const readBinaryFile = common.readBinaryFile;
const unmapBinaryFile = common.unmapBinaryFile;
const loadRuntimeSystemConfig = common.loadRuntimeSystemConfig;
const saveGuestRegistry = common.saveGuestRegistry;

pub fn cmdRun(client: *api.DiosixClient, args: []const [*:0]const u8) !void {
    const exe_name = common.getExeName();
    const allocator = std.heap.page_allocator;
    if (args.len == 0) {
        common.printFmt(
            \\Usage: {s} run <image|name> [--name <name>] [--vcpus <N>]
            \\       [--ram <size>] [--pcpu <1-90>] [--ram-quota <size>]
            \\       [--disk <disk>] [--cdrom <iso>] [--initrd <path>]
            \\       [--cmdline <args>] [--ip <ip>]
            \\       [--net <none|local|wan|router>] [--net-via <vm|cid>]
            \\       [--manifest <path>] [--domain <domain>] [--trusted]
            \\       [--arch <arch>]
            \\
        , .{exe_name});
        return;
    }

    const sys_cfg = loadRuntimeSystemConfig();
    var opts = run_opts.parseRunArgs(
        args,
        sys_cfg.default_vcpus,
        sys_cfg.defaultRam(),
        sys_cfg.defaultArch(),
        exe_name,
    ) orelse return;

    var domain_strings = OwnedStrings.init(allocator);
    defer domain_strings.deinit();

    if (opts.domain_name) |dname| {
        if (opts.vm_name == null) opts.vm_name = dname;
        const m_file = opts.manifest_path orelse sys_cfg.systemManifestPath();
        if (readBinaryFile(m_file, MAX_MANIFEST_SIZE)) |m_content| {
            defer unmapBinaryFile(m_content);
            if (manifest.parseSystemManifest(allocator, m_content)) |sys_m_v| {
                var sys_m = sys_m_v;
                defer sys_m.deinit();
                if (sys_m.domains.get(dname)) |dom| {
                    vm_stage.copyDomainFields(
                        &domain_strings,
                        dom,
                        &opts.elf_path,
                        &opts.ram_str,
                        &opts.disk_str,
                        &opts.cdrom_str,
                        &opts.ip_str,
                    ) catch return printStr(OOM_MSG);
                    run_opts.copyDomainBootExtras(
                        &domain_strings,
                        dom,
                        &opts.initrd_str,
                        &opts.cmdline_str,
                    ) catch return printStr(OOM_MSG);
                    if (dom.vcpus > 0 and opts.vcpus == 1) {
                        opts.vcpus = dom.vcpus;
                    }
                    if (opts.net_mode == null) {
                        opts.net_mode = net.inferDomainNetMode(dom);
                    }
                }
            } else |_| {}
        } else |_| {}
    }

    var direct_shim_payload_path: ?[]const u8 = null;
    if (opts.elf_path) |ep| {
        if (std.mem.endsWith(u8, ep, ".iso")) {
            if (opts.cdrom_str == null) opts.cdrom_str = ep;
            if (opts.vm_name == null) {
                const base = if (std.mem.lastIndexOfScalar(u8, ep, '/')) |s|
                    ep[s + 1 ..]
                else
                    ep;
                opts.vm_name = if (base.len > 4)
                    base[0 .. base.len - 4]
                else
                    base;
            }
            opts.elf_path = "guest-shim";
        } else if (std.mem.endsWith(u8, ep, ".img") or
            std.mem.endsWith(u8, ep, ".raw"))
        {
            if (opts.disk_str == null) opts.disk_str = ep;
            if (opts.vm_name == null) {
                const base = if (std.mem.lastIndexOfScalar(u8, ep, '/')) |s|
                    ep[s + 1 ..]
                else
                    ep;
                opts.vm_name = if (base.len > 4)
                    base[0 .. base.len - 4]
                else
                    base;
            }
            opts.elf_path = "guest-shim";
        } else if (std.mem.endsWith(u8, ep, ".efi")) {
            direct_shim_payload_path = ep;
            if (opts.vm_name == null) {
                const base = if (std.mem.lastIndexOfScalar(u8, ep, '/')) |s|
                    ep[s + 1 ..]
                else
                    ep;
                opts.vm_name = if (base.len > 4)
                    base[0 .. base.len - 4]
                else
                    base;
            }
            opts.elf_path = "guest-shim";
        }
    } else if (opts.cdrom_str != null or opts.disk_str != null) {
        opts.elf_path = "guest-shim";
    }

    if (opts.elf_path == null) {
        return common.printFmt(
            "Error: No ELF binary specified. Use '{s} run <image>' " ++
                "or specify --manifest and --domain.\n",
            .{exe_name},
        );
    }
    if (opts.vm_name == null) {
        const ep = opts.elf_path.?;
        opts.vm_name = if (std.mem.lastIndexOfScalar(u8, ep, '/')) |slash|
            ep[slash + 1 ..]
        else
            ep;
    }

    common.printFmt(
        "[10%] Resolving guest image '{s}'...\n",
        .{opts.elf_path.?},
    );
    const elf_found = vm_stage.resolveElfImage(opts.elf_path.?) catch {
        return printStr(OOM_MSG);
    };
    const elf_data = elf_found orelse {
        return common.printFmt(
            "Error: Guest ELF binary '{s}' not found (checked current dir, " ++
                "{s}/).\n",
            .{ opts.elf_path.?, sys_cfg.imagesDir() },
        );
    };
    var swapped_shim_data: ?[]u8 = null;
    defer if (swapped_shim_data) |s| unmapBinaryFile(s);
    defer unmapBinaryFile(elf_data);

    var extra_shim_payload: []const u8 = &.{};
    if (loader.isPe32PlusEfi(elf_data)) {
        const shim_found = vm_stage.resolveElfImage("guest-shim") catch null;
        if (shim_found) |s_data| {
            extra_shim_payload = elf_data;
            swapped_shim_data = s_data;
        }
    }
    const active_kernel_data = swapped_shim_data orelse elf_data;

    const dtb_data = fdt_patch.loadHostOrCustomDtb(opts.dtb_path);
    defer unmapBinaryFile(dtb_data);

    var initrd_data: []u8 = &[_]u8{};
    if (opts.initrd_str) |ir_path| {
        initrd_data = vm_stage.resolveElfImage(ir_path) catch null orelse
            (readBinaryFile(ir_path, MAX_ELF_FILE_SIZE) catch {
                return common.printFmt(
                    "Error: Initrd file '{s}' not found.\n",
                    .{ir_path},
                );
            });
    }
    defer unmapBinaryFile(initrd_data);

    var final_disk_buf: [MAX_PATH_LEN]u8 = undefined;
    const final_disk = vm_stage.resolveRunDisk(
        opts.disk_str,
        opts.vm_name.?,
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
    if (opts.cdrom_str) |c| {
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
    const payload_path = if (direct_shim_payload_path) |dp|
        dp
    else if (final_cdrom.len > 0)
        final_cdrom
    else
        final_disk;
    if (extra_shim_payload.len == 0 and payload_path.len > 0) {
        if (readBinaryFile(payload_path, MAX_MEDIA_FILE_SIZE)) |cd_data| {
            shim_payload_data = cd_data;
        } else |_| {}
    }
    defer unmapBinaryFile(shim_payload_data);
    const eff_shim_payload = if (extra_shim_payload.len > 0)
        extra_shim_payload
    else
        shim_payload_data;

    const req_arch = std.meta.stringToEnum(
        api.TargetArch,
        opts.arch_str,
    ) orelse .riscv64;
    const arch_enum = loader.checkGuestArch(
        active_kernel_data,
        req_arch,
    ) orelse {
        if (!@import("builtin").is_test) std.process.exit(1);
        return;
    };
    const ram_mb = parseMemorySizeMb(opts.ram_str);
    const raw_quota_mb = if (opts.ram_quota_str) |rq|
        parseMemorySizeMb(rq)
    else
        ram_mb;
    const ram_quota_mb = @max(ram_mb, raw_quota_mb);
    const eff_pcpu = vm_stage.checkChildResourceQuota(
        client,
        opts.vm_name.?,
        opts.vcpus,
        ram_mb,
        opts.pcpu_pct,
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
    const eff_net_mode = opts.net_mode orelse .local;
    const upstream_cid: usize = if (opts.net_via_str) |vs|
        net.resolveUpstreamCid(vs) orelse {
            common.printFmt(
                "Error: Unknown upstream router VM '{s}'.\n",
                .{vs},
            );
            return;
        }
    else
        0;

    var run_flags: usize = if (opts.trusted) api.RunFlags.TRUSTED else 0;
    if (opts.is_steward) run_flags |= api.RunFlags.STEWARD;
    if (opts.is_standby_root) run_flags |= api.RunFlags.STANDBY_ROOT;
    if (opts.is_confidential) run_flags |= api.RunFlags.CONFIDENTIAL;
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
        opts.vcpus,
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

    const default_ip: ?[]u8 = if (opts.ip_str.len > 0)
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
    const final_ip: []const u8 = default_ip orelse opts.ip_str;

    const inject_key = !opts.is_confidential and !opts.is_steward;
    vm_stage.stageChildVmManifest(
        allocator,
        client,
        child_cid,
        opts.vm_name.?,
        opts.domain_name,
        opts.manifest_path,
        inject_key,
    );
    net.applyVmNetConfig(
        allocator,
        client,
        child_cid,
        final_ip,
        eff_net_mode,
        upstream_cid,
    );

    const is_shim_boot = std.mem.eql(u8, opts.elf_path.?, "guest-shim") or
        swapped_shim_data != null;
    var ip_autoconfig: ?[]u8 = null;
    defer if (ip_autoconfig) |ipa| allocator.free(ipa);
    if (is_shim_boot and eff_net_mode != .none and final_ip.len > 0) {
        const gw_host: usize = if (upstream_cid >= common.CID_FIRST_CHILD)
            upstream_cid
        else
            1;
        const resolv_raw = readBinaryFile(
            sysconfig.RESOLV_CONF_PATH,
            4096,
        ) catch &[_]u8{};
        defer unmapBinaryFile(resolv_raw);
        const dns_sfx = fdt_guest.formatDnsSuffixFromResolv(
            allocator,
            resolv_raw,
        ) catch null;
        defer if (dns_sfx) |d| allocator.free(d);
        ip_autoconfig = allocator.print(
            "{s}::{s}{d}:255.255.255.0:{s}:eth0:off{s}",
            .{
                final_ip,
                sys_cfg.subnetPrefix(),
                gw_host,
                opts.vm_name.?,
                dns_sfx orelse "",
            },
        ) catch null;
    }

    const base_gpa: usize = switch (arch_enum) {
        .x86_64 => 0,
        .aarch64 => 0x40000000,
        .riscv64, .riscv32 => 0xe0000000,
    };
    _ = loader.loadGuestImageViaForeignMapping(
        client,
        child_cid,
        active_kernel_data,
        dtb_data,
        eff_shim_payload,
        .{
            .initrd_data = initrd_data,
            .cmdline = opts.cmdline_str,
            .is_shim_boot = is_shim_boot,
            .ip_autoconfig = ip_autoconfig,
        },
        base_gpa,
        ram_mb << MIB_SHIFT,
        opts.vcpus,
    ) catch |err| {
        printApiError("Load guest ELF", err);
        _ = client.terminate(child_cid, 1) catch {};
        if (!@import("builtin").is_test) std.process.exit(1);
        return;
    };

    const raw_img = opts.elf_path.?;
    const img_name = if (std.mem.lastIndexOfScalar(u8, raw_img, '/')) |slash|
        raw_img[slash + 1 ..]
    else
        raw_img;
    saveGuestRegistry(
        child_cid,
        opts.vm_name.?,
        img_name,
        opts.vcpus,
        final_ram_str,
        final_disk,
        final_cdrom,
        final_ip,
        if (opts.trusted) "trusted" else "untrusted",
        "running",
    );
    vm_stage.printRunSuccess(
        opts.vm_name.?,
        child_cid,
        opts.vcpus,
        final_ram_str,
        final_disk,
        final_cdrom,
        final_ip,
    );
}

test "vm_run: RunOption enum parses expected CLI flags" {
    std.testing.refAllDecls(@This());
    _ = run_opts;
    try std.testing.expectEqual(
        run_opts.RunOption.@"--domain",
        std.meta.stringToEnum(run_opts.RunOption, "--domain").?,
    );
}
