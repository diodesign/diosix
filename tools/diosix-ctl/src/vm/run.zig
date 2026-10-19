// Diosix Hypervisor Guest Management CLI — VM Spawn (dsx run).
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const api = @import("../api.zig");
const manifest = @import("../manifest.zig");
const common = @import("../common.zig");
const loader = @import("../loader.zig");
const vm_stage = @import("stage.zig");

const MAX_PATH_LEN = common.MAX_PATH_LEN;
const MAX_ELF_FILE_SIZE = common.MAX_ELF_FILE_SIZE;
const MAX_DTB_FILE_SIZE = common.MAX_DTB_FILE_SIZE;
const MAX_MANIFEST_SIZE = common.MAX_MANIFEST_SIZE;
const PAGE_SIZE_KB = common.PAGE_SIZE_KB;
const KB_PER_MB = common.KB_PER_MB;
pub const MIB_SHIFT: u6 = 20;

const printStr = common.printStr;
const isArch = common.isArch;
const printApiError = common.printApiError;
const copyStr = common.copyStr;
const parseMemorySizeMb = common.parseMemorySizeMb;
const readBinaryFile = common.readBinaryFile;
const unmapBinaryFile = common.unmapBinaryFile;
const loadRuntimeSystemConfig = common.loadRuntimeSystemConfig;
const saveGuestRegistry = common.saveGuestRegistry;

const RunOption = enum {
    @"--name",
    @"--domain",
    @"--manifest",
    @"-m",
    @"--vcpus",
    @"--ram",
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
    @"--user",
};

pub fn cmdRun(client: *api.DiosixClient, args: []const [*:0]const u8) !void {
    const exe_name = common.getExeName();
    const allocator = std.heap.page_allocator;
    if (args.len == 0) {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf,
            \\Usage: {s} run <image|name> [--name <name>] [--vcpus <N>]
            \\       [--ram <size>] [--disk <disk>] [--cdrom <iso>] [--ip <ip>]
            \\       [--manifest <path>] [--domain <domain>] [--trusted]
            \\       [--arch <arch>]
            \\
        , .{exe_name}) catch return;
        printStr(msg);
        return;
    }

    const sys_cfg = loadRuntimeSystemConfig();
    var elf_path: ?[]const u8 = null;
    var vm_name: ?[]const u8 = null;
    var domain_name: ?[]const u8 = null;
    var manifest_path: ?[]const u8 = null;
    var vcpus: usize = sys_cfg.default_vcpus;
    var ram_str: []const u8 = sys_cfg.defaultRam();
    var disk_str: ?[]const u8 = null;
    var cdrom_str: ?[]const u8 = null;
    var ip_str: []const u8 = "";
    var trusted: bool = false;
    var is_steward: bool = false;
    var is_standby_root: bool = false;
    var is_confidential: bool = false;
    var arch_str: []const u8 = sys_cfg.defaultArch();
    var dtb_path: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const span = std.mem.span(args[i]);
        if (std.meta.stringToEnum(RunOption, span)) |opt| {
            switch (opt) {
                .@"--name" => {
                    if (i + 1 >= args.len) {
                        printStr(
                            "Error: Option '--name' requires a VM name.\n",
                        );
                        return;
                    }
                    i += 1;
                    vm_name = std.mem.span(args[i]);
                },
                .@"--domain" => {
                    if (i + 1 >= args.len) {
                        printStr("Error: '--domain' requires a domain name.\n");
                        return;
                    }
                    i += 1;
                    domain_name = std.mem.span(args[i]);
                },
                .@"--manifest", .@"-m" => {
                    if (i + 1 >= args.len) {
                        printStr("Error: '--manifest' requires a file path.\n");
                        return;
                    }
                    i += 1;
                    manifest_path = std.mem.span(args[i]);
                },
                .@"--vcpus" => {
                    if (i + 1 >= args.len) {
                        printStr("Error: '--vcpus' requires a count.\n");
                        return;
                    }
                    i += 1;
                    vcpus = std.fmt.parseInt(
                        usize,
                        std.mem.span(args[i]),
                        10,
                    ) catch {
                        printStr("Error: Invalid '--vcpus' value.\n");
                        return;
                    };
                    if (vcpus == 0) {
                        printStr("Error: '--vcpus' must be at least 1.\n");
                        return;
                    }
                },
                .@"--ram" => {
                    if (i + 1 >= args.len) {
                        printStr("Error: '--ram' requires a size.\n");
                        return;
                    }
                    i += 1;
                    ram_str = std.mem.span(args[i]);
                },
                .@"--disk", .@"-d" => {
                    if (i + 1 >= args.len) {
                        printStr("Error: '--disk' requires a disk or size.\n");
                        return;
                    }
                    i += 1;
                    disk_str = std.mem.span(args[i]);
                },
                .@"--cdrom", .@"--iso", .@"--media" => {
                    if (i + 1 >= args.len) {
                        printStr("Error: '--cdrom' requires a media path.\n");
                        return;
                    }
                    i += 1;
                    cdrom_str = std.mem.span(args[i]);
                },
                .@"--ip" => {
                    if (i + 1 >= args.len) {
                        printStr("Error: '--ip' requires an IP address.\n");
                        return;
                    }
                    i += 1;
                    ip_str = std.mem.span(args[i]);
                },
                .@"--trusted" => trusted = true,
                .@"--untrusted" => trusted = false,
                .@"--steward" => is_steward = true,
                .@"--standby-root" => is_standby_root = true,
                .@"--confidential" => is_confidential = true,
                .@"--dtb" => {
                    if (i + 1 >= args.len) {
                        printStr("Error: '--dtb' requires a DTB path.\n");
                        return;
                    }
                    i += 1;
                    dtb_path = std.mem.span(args[i]);
                },
                .@"--arch", .@"-a" => {
                    if (i + 1 >= args.len) {
                        printStr("Error: '--arch' requires an arch name.\n");
                        return;
                    }
                    i += 1;
                    arch_str = std.mem.span(args[i]);
                },
                .@"--user" => {
                    printStr(
                        "Error: Unrecognized option '--user'. " ++
                            "To specify a VM name, use '--name <name>'.\n",
                    );
                    return;
                },
            }
        } else if (isArch(span)) {
            arch_str = span;
        } else if (std.mem.startsWith(u8, span, "-")) {
            var err_buf: [128]u8 = undefined;
            const err_msg = std.fmt.bufPrint(
                &err_buf,
                "Error: Unknown option '{s}'. Use '{s} run' for usage.\n",
                .{ span, exe_name },
            ) catch "Error: Unknown option.\n";
            printStr(err_msg);
            return;
        } else if (elf_path == null) {
            elf_path = span;
        }
    }

    // Owned stack buffers so domain manifest fields outlive unmapping.
    var dom_img_buf: [MAX_PATH_LEN]u8 = undefined;
    var dom_ram_buf: [32]u8 = undefined;
    var dom_disk_buf: [MAX_PATH_LEN]u8 = undefined;
    var dom_cdrom_buf: [MAX_PATH_LEN]u8 = undefined;
    var dom_ip_buf: [64]u8 = undefined;

    if (domain_name) |dname| {
        if (vm_name == null) vm_name = dname;
        const m_file = manifest_path orelse sys_cfg.systemManifestPath();
        if (readBinaryFile(m_file, MAX_MANIFEST_SIZE)) |m_content| {
            defer unmapBinaryFile(m_content);
            if (manifest.parseSystemManifest(allocator, m_content)) |sys_m_v| {
                var sys_m = sys_m_v;
                defer sys_m.deinit();
                if (sys_m.domains.get(dname)) |dom| {
                    if (elf_path == null and dom.image.len > 0) {
                        elf_path = copyStr(&dom_img_buf, dom.image);
                    }
                    if (dom.vcpus > 0 and vcpus == 1) vcpus = dom.vcpus;
                    const is_def_ram = std.mem.eql(u8, ram_str, "256 MB");
                    if (dom.ram.len > 0 and is_def_ram) {
                        ram_str = copyStr(&dom_ram_buf, dom.ram);
                    }
                    if (disk_str == null and dom.disk.len > 0) {
                        disk_str = copyStr(&dom_disk_buf, dom.disk);
                    }
                    if (cdrom_str == null and dom.cdrom.len > 0) {
                        cdrom_str = copyStr(&dom_cdrom_buf, dom.cdrom);
                    }
                    if (dom.ip.len > 0 and ip_str.len == 0) {
                        ip_str = copyStr(&dom_ip_buf, dom.ip);
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
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &buf,
            "Error: No ELF binary specified. Use '{s} run <image>' " ++
                "or specify --manifest and --domain.\n",
            .{exe_name},
        ) catch return;
        printStr(msg);
        return;
    }

    if (vm_name == null) {
        const ep = elf_path.?;
        vm_name = if (std.mem.lastIndexOfScalar(u8, ep, '/')) |slash|
            ep[slash + 1 ..]
        else
            ep;
    }

    var resolved_buf: [MAX_PATH_LEN]u8 = undefined;
    const elf_data = vm_stage.resolveElfImage(
        elf_path.?,
        &resolved_buf,
    ) orelse {
        var err_buf: [MAX_PATH_LEN + 128]u8 = undefined;
        const err_msg = std.fmt.bufPrint(
            &err_buf,
            "Error: Guest ELF binary '{s}' not found (checked current dir, " ++
                "/var/lib/diosix/images/).\n",
            .{elf_path.?},
        ) catch "Error: ELF binary not found.\n";
        printStr(err_msg);
        return;
    };
    defer unmapBinaryFile(elf_data);

    const dtb_src = dtb_path orelse "/sys/firmware/fdt";
    var dtb_data: []u8 = &[_]u8{};
    if (readBinaryFile(dtb_src, MAX_DTB_FILE_SIZE)) |dd| {
        dtb_data = dd;
    } else |_| {}
    defer unmapBinaryFile(dtb_data);

    var final_disk_buf: [MAX_PATH_LEN]u8 = undefined;
    const final_disk =
        vm_stage.resolveRunDisk(disk_str, vm_name.?, &final_disk_buf);

    var final_cdrom_buf: [MAX_PATH_LEN]u8 = undefined;
    var final_cdrom: []const u8 = "";
    if (cdrom_str) |c| {
        if (std.mem.startsWith(u8, c, "/")) {
            final_cdrom = c;
        } else if (std.mem.endsWith(u8, c, ".iso") or
            std.mem.endsWith(u8, c, ".raw"))
        {
            final_cdrom = std.fmt.bufPrint(
                &final_cdrom_buf,
                "{s}/{s}",
                .{ sys_cfg.isoDir(), c },
            ) catch c;
        } else {
            final_cdrom = std.fmt.bufPrint(
                &final_cdrom_buf,
                "{s}/{s}.iso",
                .{ sys_cfg.isoDir(), c },
            ) catch c;
        }
    }

    var shim_payload_data: []u8 = &[_]u8{};
    if (final_cdrom.len > 0) {
        if (readBinaryFile(final_cdrom, MAX_ELF_FILE_SIZE)) |cd_data| {
            shim_payload_data = cd_data;
        } else |_| {}
    }
    defer unmapBinaryFile(shim_payload_data);

    const arch_enum =
        std.meta.stringToEnum(api.TargetArch, arch_str) orelse .riscv64;
    var run_flags: usize = if (trusted) api.RunFlags.TRUSTED else 0;
    if (is_steward) run_flags |= api.RunFlags.STEWARD;
    if (is_standby_root) run_flags |= api.RunFlags.STANDBY_ROOT;
    if (is_confidential) run_flags |= api.RunFlags.CONFIDENTIAL;
    const child_cid = client.run(
        0,
        &[_]u8{},
        &[_]u8{},
        @backingInt(arch_enum),
        run_flags,
    ) catch |err| {
        printApiError("Create child VM", err);
        return;
    };

    const ram_mb = parseMemorySizeMb(ram_str);
    const ram_pages = (ram_mb * KB_PER_MB) / PAGE_SIZE_KB;
    _ = client.setQuota(child_cid, ram_pages, 0, 0, 0) catch {};

    vm_stage.stageChildVmManifest(
        allocator,
        client,
        child_cid,
        vm_name.?,
        domain_name,
        manifest_path,
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
        return;
    };

    var final_ip_buf: [64]u8 = undefined;
    const final_ip: []const u8 = if (ip_str.len > 0)
        ip_str
    else
        std.fmt.bufPrint(
            &final_ip_buf,
            "{s}{d}",
            .{ sys_cfg.subnetPrefix(), child_cid },
        ) catch "10.0.3.2";

    var final_ram_buf: [32]u8 = undefined;
    const final_ram_str = std.fmt.bufPrint(
        &final_ram_buf,
        "{d} MB",
        .{ram_mb},
    ) catch "256 MB";

    saveGuestRegistry(
        child_cid,
        vm_name.?,
        vcpus,
        final_ram_str,
        final_disk,
        final_cdrom,
        final_ip,
        if (trusted) "trusted" else "untrusted",
        "running",
    );

    printRunSuccess(
        vm_name.?,
        child_cid,
        vcpus,
        final_ram_str,
        final_disk,
        final_cdrom,
        final_ip,
    );
}

fn printRunSuccess(
    vm_name: []const u8,
    child_cid: usize,
    vcpus: usize,
    ram_str: []const u8,
    disk: []const u8,
    cdrom: []const u8,
    ip: []const u8,
) void {
    var msg_buf: [384]u8 = undefined;
    const out_msg = if (disk.len > 0 and cdrom.len > 0)
        std.fmt.bufPrint(
            &msg_buf,
            "✓ Child VM '{s}' (CID {d}, {d} vCPUs, {s} RAM, " ++
                "Disk: {s}, CD-ROM: {s}, IP: {s}) started in background.\n",
            .{ vm_name, child_cid, vcpus, ram_str, disk, cdrom, ip },
        ) catch return
    else if (disk.len > 0)
        std.fmt.bufPrint(
            &msg_buf,
            "✓ Child VM '{s}' (CID {d}, {d} vCPUs, {s} RAM, " ++
                "Disk: {s}, IP: {s}) started in background.\n",
            .{ vm_name, child_cid, vcpus, ram_str, disk, ip },
        ) catch return
    else if (cdrom.len > 0)
        std.fmt.bufPrint(
            &msg_buf,
            "✓ Child VM '{s}' (CID {d}, {d} vCPUs, {s} RAM, " ++
                "CD-ROM: {s}, IP: {s}) started in background.\n",
            .{ vm_name, child_cid, vcpus, ram_str, cdrom, ip },
        ) catch return
    else
        std.fmt.bufPrint(
            &msg_buf,
            "✓ Child VM '{s}' (CID {d}, {d} vCPUs, {s} RAM, " ++
                "IP: {s}) started in background.\n",
            .{ vm_name, child_cid, vcpus, ram_str, ip },
        ) catch return;
    printStr(out_msg);
}

test "vm_run: RunOption enum parses expected CLI flags" {
    std.testing.refAllDecls(@This());
    _ = vm_stage;
    try std.testing.expectEqual(
        RunOption.@"--domain",
        std.meta.stringToEnum(RunOption, "--domain").?,
    );
}
