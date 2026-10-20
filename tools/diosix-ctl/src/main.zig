// Diosix Hypervisor Guest Management CLI.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
pub const api = @import("api.zig");
pub const manifest = @import("manifest.zig");
pub const catalog = @import("catalog.zig");
pub const passkey = @import("passkey.zig");
pub const installer = @import("installer.zig");
pub const charter = @import("charter.zig");
pub const sysconfig = @import("sysconfig.zig");
pub const common = @import("common.zig");
pub const loader = @import("loader.zig");
pub const ssh = @import("ssh.zig");
pub const storage = @import("storage.zig");
pub const vm = @import("vm.zig");
pub const host = @import("host.zig");
pub const governance = @import("governance.zig");
const main_tests = @import("tests/main.zig");

pub const CID_PARENT = common.CID_PARENT;
pub const CID_SELF = common.CID_SELF;
pub const CID_FIRST_CHILD = common.CID_FIRST_CHILD;
pub const MAX_POSITIONAL_ARGS = common.MAX_POSITIONAL_ARGS;
pub const MAX_IPC_BUF_LEN = common.MAX_IPC_BUF_LEN;
pub const MAX_PATH_LEN = common.MAX_PATH_LEN;
pub const MAX_ELF_FILE_SIZE = common.MAX_ELF_FILE_SIZE;
pub const MAX_DTB_FILE_SIZE = common.MAX_DTB_FILE_SIZE;
pub const MAX_MANIFEST_SIZE = common.MAX_MANIFEST_SIZE;
pub const PAGE_SIZE_KB = common.PAGE_SIZE_KB;
pub const KB_PER_MB = common.KB_PER_MB;

pub const formatGuestDetail = vm.formatGuestDetail;
pub const formatSelfInfo = vm.formatSelfInfo;
pub const formatVersionChannel = host.formatVersionChannel;
pub const formatHostInfo = host.formatHostInfo;
pub const sanitizeJsonStr = common.sanitizeJsonStr;
pub const parseIpv4 = ssh.parseIpv4;

const printStr = common.printStr;
const printFmt = common.printFmt;
const parseCid = common.parseCid;
const getExeName = common.getExeName;

pub const Command = enum {
    host,
    info,
    run,
    create,
    @"install-guest",
    list,
    ps,
    ls,
    ssh,
    login,
    console,
    exec,
    stop,
    kill,
    terminate,
    restart,
    disk,
    storage,
    image,
    iso,
    snapshot,
    manifest,
    auth,
    passkey,
    gui,
    tour,
    charter,
    steward,
    resolve,
    quota,
    @"drop-trust",
    poweroff,
    shutdown,
    reboot,
    help,
    @"--help",
    @"-h",
};

const ResolveOption = enum {
    @"--manifest",
    @"-m",
};

pub fn main(init: std.process.Init.Minimal) !void {
    const argv = init.args.vector;
    if (argv.len > 0) {
        common.setExeName(argv[0]);
    }

    if (argv.len < 2) {
        printUsage();
        return;
    }

    var client = api.DiosixClient.init();
    defer client.deinit();

    const command_raw = std.mem.span(argv[1]);

    if (std.meta.stringToEnum(Command, command_raw)) |cmd| {
        switch (cmd) {
            .host => try host.cmdHost(&client, argv[2..]),
            .info => try vm.cmdInfo(&client, argv[2..]),
            .run, .create => try vm.cmdRun(&client, argv[2..]),
            .@"install-guest" => try vm.cmdInstallGuest(&client, argv[2..]),
            .list, .ps, .ls => try vm.cmdList(&client),
            .ssh, .login, .console, .exec => {
                try ssh.cmdSsh(&client, argv[2..]);
            },
            .stop, .kill, .terminate => _ = try vm.cmdStop(&client, argv[2..]),
            .restart => try vm.cmdRestart(&client, argv[2..]),
            .disk, .storage => try storage.cmdDisk(&client, argv[2..]),
            .image, .iso => try storage.cmdImage(&client, argv[2..]),
            .snapshot => try storage.cmdSnapshot(&client, argv[2..]),
            .manifest => try governance.cmdManifest(&client, argv[2..]),
            .auth, .passkey => try governance.cmdAuth(&client, argv[2..]),
            .gui => try host.cmdGui(&client, argv[2..]),
            .tour => try host.cmdTour(argv[2..]),
            .charter, .steward => {
                try governance.cmdCharter(&client, argv[2..]);
            },
            .resolve => {
                if (argv.len < 3) {
                    printFmt(
                        "Usage: {s} manifest resolve <service_alias> " ++
                            "[--manifest <file.toml>]\n",
                        .{getExeName()},
                    );
                    return;
                }
                const service_name = std.mem.span(argv[2]);
                var m_path: ?[]const u8 = null;
                for (argv[3..], 3..) |arg, i| {
                    const span = std.mem.span(arg);
                    if (std.meta.stringToEnum(ResolveOption, span) != null and
                        argv.len > i + 1)
                    {
                        m_path = std.mem.span(argv[i + 1]);
                    }
                }
                try governance.cmdResolve(&client, service_name, m_path);
            },
            .quota => {
                var target_cid: usize = 1;
                if (argv.len >= 3 and
                    !std.mem.startsWith(u8, std.mem.span(argv[2]), "-"))
                {
                    const span = std.mem.span(argv[2]);
                    if (std.meta.stringToEnum(common.TargetAlias, span)) |al| {
                        if (al == .parent or al == .@"0") {
                            printStr(
                                "Error: Cannot query or set quotas " ++
                                    "on parent VM (CID 0).\n",
                            );
                            return;
                        }
                    }
                    target_cid = parseCid(span) catch {
                        printFmt(
                            "Error: Invalid target CID '{s}'.\n",
                            .{span},
                        );
                        return;
                    };
                }
                try vm.cmdQuota(&client, target_cid, argv);
            },
            .@"drop-trust" => try vm.cmdDropTrust(&client),
            .poweroff, .shutdown => try host.cmdPoweroff(&client),
            .reboot => try host.cmdReboot(&client),
            .help, .@"--help", .@"-h" => printUsage(),
        }
    } else {
        printFmt(
            "Unknown command '{s}'. Use '{s} help' for available commands.\n",
            .{ command_raw, getExeName() },
        );
    }
}

fn printUsage() void {
    const allocator = std.heap.page_allocator;
    const usage = formatUsage(allocator, getExeName()) catch {
        printStr("Error: Out of memory while printing help.\n");
        return;
    };
    defer allocator.free(usage);
    printStr(usage);
}

/// Formats the help text. The caller owns the returned slice.
pub fn formatUsage(
    allocator: std.mem.Allocator,
    exe_name: []const u8,
) ![]u8 {
    return allocator.print(
        \\{s}: Diosix type-1 hypervisor guest management CLI
        \\
        \\Usage:
        \\  {s} run <image|name> [options]       Launch child VM with SSH net
        \\      [--name <name>]                  Assign human-friendly VM name
        \\      [--vcpus <N>]                    Allocate virtual CPUs
        \\      [--ram <size>]                   Allocate RAM limit ('256M')
        \\      [--disk <name|size>]             Attach or create virtual disk
        \\      [--cdrom <iso|path>]             Attach installer ISO (RO)
        \\      [--ip <addr>]                    Assign private IP address
        \\      [--manifest <file.toml>]         Stage attenuated manifest
        \\      [--domain <name>]                Extract domain from manifest
        \\      [--trusted]                      Grant hardware trust
        \\  {s} install-guest <os|iso> [options] Provision disk & boot ISO
        \\      [--name <name>]                  Assign VM name
        \\      [--disk <name>]                  Target virtual disk name
        \\      [--size <size>]                  Virtual disk capacity (4GiB)
        \\      [--vcpus <N>] [--ram <size>]     Override vCPU and RAM limits
        \\  {s} list / {s} ps                    List active VMs & endpoints
        \\  {s} ssh [user@]<name|cid> [-- [cmd]] Open interactive SSH shell
        \\  {s} stop <name|cid|self>             Stop and terminate guest VM
        \\  {s} kill <name|cid|self>             Alias for stop
        \\  {s} restart <name|cid>               Restart a running guest VM
        \\  {s} info [name|cid|self] [--json]    Display guest VM status
        \\  {s} quota <cid|self> [options]       Set VM resource quotas
        \\
        \\  {s} disk <subcmd> [options]          Manage persistent VM disks
        \\      create <name> [--size <size>]    Create virtual disk image
        \\      list                             List virtual disk images
        \\      delete <name>                    Delete virtual disk image
        \\      resize <name> --size <size>      Resize virtual disk image
        \\
        \\  {s} image <subcmd> [options]         Manage kernels, Stewards & ISOs
        \\      list [--remote]                  List local or catalog images
        \\      catalog [--json]                 List Guest OS & Steward catalog
        \\      pull <catalog-id|url> [options]  Pull & verify SHA-256 image
        \\      import <file> [--name <name>]    Import local ISO or ELF
        \\      delete <name>                    Delete image or ISO
        \\
        \\  {s} auth <subcmd> [options]          Manage passkey authentication
        \\      status [--json]                  Show passkey security posture
        \\      list [--json]                    List enrolled passkeys
        \\      enroll [options]                 Enroll FIDO2/TPM/QR passkey
        \\      challenge [--json]               Generate 256-bit UART nonce
        \\      verify <sig-hex> [--json]        Verify Ed25519 signature
        \\
        \\  {s} snapshot <subcmd> [options]      Manage VM state snapshots
        \\      save <name|cid> [snap_id]        Save running VM checkpoint
        \\      list                             List saved snapshots
        \\      restore <snap_id>                Restore VM state from snapshot
        \\      delete <snap_id>                 Delete saved snapshot
        \\
        \\  {s} host info [--json]               Display host hardware & HV info
        \\  {s} host install [options]           Install Diosix to host storage
        \\  {s} host reboot                      Reboot physical machine
        \\  {s} host poweroff / shutdown         Power off physical machine
        \\
        \\  {s} charter <subcmd> [options]       Manage Constitutional Charter
        \\      status [--file <path>] [--json]  Show Charter & M-mode state
        \\      deploy [--file <path>] [options] Seal Charter in M-mode
        \\      propose <action> [options]       Evaluate Steward proposal
        \\      ratify [--target <cid>]          Cast Steward ratification vote
        \\      whisper <send|recv> [options]    Steward Whisper Protocol IPC
        \\      reset-steward <cid>              Reset compromised Steward VM
        \\      failover [--standby <cid>]       Promote Standby Root VM
        \\      audit [--json]                   Audit constitutional compliance
        \\
        \\  {s} gui <subcmd> [options]           Manage graphical seat & OSK
        \\  {s} tour [--step <1..5>] [--json]    Interactive guided tour
        \\
        \\  {s} manifest <subcmd> [options]      Manage system & VM manifests
        \\      show [--file <path>] [--hv]      Display active or file manifest
        \\      validate <file.toml>             Validate manifest syntax
        \\      prune <sys.toml> --domain <d>    Attenuate manifest for child
        \\      resolve <service_alias>          Resolve service route
        \\      set <cid> <file.toml>            Stage manifest for child VM
        \\
        \\  {s} drop-trust                       Relinquish hardware trust
        \\  {s} help                             Show this help message
        \\
    , .{
        exe_name, exe_name, exe_name, exe_name, exe_name,
        exe_name, exe_name, exe_name, exe_name, exe_name,
        exe_name, exe_name, exe_name, exe_name, exe_name,
        exe_name, exe_name, exe_name, exe_name, exe_name,
        exe_name, exe_name, exe_name, exe_name, exe_name,
    });
}

test "help text is formatted in full and is not truncated" {
    const usage = try formatUsage(std.testing.allocator, "dsx");
    defer std.testing.allocator.free(usage);

    // Regression: help text once exceeded a 4096-byte stack buffer, so the
    // format call failed and the error was silently swallowed.
    try std.testing.expect(usage.len > 4096);
    try std.testing.expect(std.mem.startsWith(u8, usage, "dsx: Diosix"));
    try std.testing.expect(std.mem.indexOf(u8, usage, "dsx help") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "{s}") == null);
}

test {
    std.testing.refAllDecls(@This());
    _ = main_tests;
}
