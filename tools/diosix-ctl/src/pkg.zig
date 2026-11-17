// Diosix Hierarchical Alpine APK Package Manager & Proxy CLI (`dsx pkg`).
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const api = @import("api.zig");
const common = @import("common.zig");
const net_http = @import("net/http.zig");
const sysconfig = @import("sysconfig.zig");
const pkg_index = @import("pkg/index.zig");
const pkg_policy = @import("pkg/policy.zig");
const pkg_server = @import("pkg/server.zig");

pub const policy = pkg_policy;
pub const index = pkg_index;
pub const server = pkg_server;

const PkgSubcmd = enum {
    status,
    policy,
    allow,
    deny,
    sync,
    serve,
    help,
    @"--help",
    @"-h",
};

const ServeOption = enum {
    @"--port",
    @"-p",
    @"--daemon",
    @"-d",
    @"--branch",
    @"--repo",
    @"--arch",
    @"--json",
    @"-j",
};

pub fn resolveChildTargetCid(target: []const u8) ?usize {
    const parsed = std.fmt.parseInt(usize, target, 10) catch 0;
    if (common.readBinaryFile(
        common.GUEST_REGISTRY_PATH,
        common.MAX_MANIFEST_SIZE,
    )) |raw| {
        defer common.unmapBinaryFile(raw);
        var it = common.GuestRegistryIter.init(raw);
        while (it.next()) |entry| {
            if (common.matchTarget(target, parsed, entry.cid, entry.name)) {
                return entry.cid;
            }
        }
    } else |_| {}
    if (parsed >= common.CID_FIRST_CHILD) return parsed;
    return null;
}

fn countApkFiles(dir_path: []const u8) usize {
    var z_buf: [common.MAX_PATH_LEN]u8 = undefined;
    const z = common.toPathZ(dir_path, &z_buf) orelse return 0;
    const fd_s: isize = @bitCast(
        linux.open(z.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0),
    );
    if (fd_s < 0) return 0;
    const fd: i32 = @intCast(fd_s);
    defer _ = linux.close(fd);

    var count: usize = 0;
    var dbuf: [4096]u8 = undefined;
    while (true) {
        const nr: isize = @bitCast(linux.getdents64(fd, &dbuf, dbuf.len));
        if (nr <= 0) break;
        var pos: usize = 0;
        const tot: usize = @intCast(nr);
        while (pos < tot) {
            const dent: *const common.LinuxDirent64 =
                @ptrCast(@alignCast(&dbuf[pos]));
            pos += dent.d_reclen;
            const dname_ptr: [*:0]const u8 = @ptrCast(&dent.d_name);
            const dname = std.mem.span(dname_ptr);
            if (std.mem.endsWith(u8, dname, ".apk")) count += 1;
        }
    }
    return count;
}

fn printPkgUsage() void {
    const exe = common.getExeName();
    common.printFmt(
        \\Usage:
        \\  {s} pkg status [--json]              Show APK proxy & ceiling state
        \\  {s} pkg policy [<vm|cid|self>] [--json]
        \\                                      Show effective allow/deny policy
        \\  {s} pkg allow <vm|cid> <*|none|csv> Set child APK allowlist
        \\  {s} pkg deny <vm|cid> <none|csv>    Set child APK denylist
        \\  {s} pkg sync [--branch B] [--repo R] Refresh APKINDEX from upstream
        \\  {s} pkg serve [--port P] [--daemon] Run attenuating APK HTTP proxy
        \\
    , .{ exe, exe, exe, exe, exe, exe });
}

fn cmdStatus(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    json_flag: bool,
) void {
    const pid = net_http.isPidFileRunning(sysconfig.PKG_PROXY_PID_PATH);
    const has_parent = net_http.isHasParent(client);
    var pol = pkg_policy.loadGuestManifestPolicy(
        allocator,
        client,
        common.CID_SELF,
    ) catch pkg_policy.PkgPolicy{};
    defer pol.deinit(allocator);

    const allow_s = pkg_policy.formatPolicyAllowValue(allocator, &pol) catch
        return;
    defer allocator.free(allow_s);
    const deny_s = pkg_policy.formatCsv(
        allocator,
        pol.deny.items,
        "none",
    ) catch return;
    defer allocator.free(deny_s);

    const seed_dir = sysconfig.DEFAULT_APK_SEED_DIR ++ "/" ++
        sysconfig.DEFAULT_APK_BRANCH ++ "/" ++
        sysconfig.DEFAULT_APK_REPO ++ "/riscv64";
    const cache_dir = sysconfig.DEFAULT_PKG_CACHE_DIR ++ "/" ++
        sysconfig.DEFAULT_APK_BRANCH ++ "/" ++
        sysconfig.DEFAULT_APK_REPO ++ "/riscv64";
    const seed_cnt = countApkFiles(seed_dir);
    const cache_cnt = countApkFiles(cache_dir);
    const upstream = if (has_parent)
        "http://diosix-parent:8080"
    else
        sysconfig.ALPINE_CDN_BASE_URL;

    if (json_flag) {
        const ae = common.escapeJsonAlloc(allocator, allow_s) catch return;
        defer allocator.free(ae);
        const de = common.escapeJsonAlloc(allocator, deny_s) catch return;
        defer allocator.free(de);
        common.printFmt(
            "{{\"running\":{},\"pid\":{d},\"port\":{d}," ++
                "\"upstream\":\"{s}\",\"seed_apks\":{d}," ++
                "\"cached_apks\":{d},\"allow\":\"{s}\",\"deny\":\"{s}\"}}\n",
            .{
                pid != null,
                pid orelse 0,
                sysconfig.DEFAULT_PKG_PORT,
                upstream,
                seed_cnt,
                cache_cnt,
                ae,
                de,
            },
        );
        return;
    }
    common.printFmt("APK proxy daemon : {s}", .{
        if (pid != null) "running" else "stopped",
    });
    if (pid) |p| common.printFmt(" (pid {d})", .{p});
    common.printFmt(
        "\nListen port      : {d}\n" ++
            "Upstream source  : {s}\n" ++
            "Seed / Cache APKs: {d} / {d}\n" ++
            "Self allow       : {s}\n" ++
            "Self deny        : {s}\n",
        .{
            sysconfig.DEFAULT_PKG_PORT,
            upstream,
            seed_cnt,
            cache_cnt,
            allow_s,
            deny_s,
        },
    );
}

fn cmdPolicy(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    args: []const [*:0]const u8,
    initial_json: bool,
) void {
    var target: []const u8 = "self";
    var json_flag = initial_json;
    for (args[1..]) |raw| {
        const s = std.mem.span(raw);
        if (common.isJsonFlag(s)) {
            json_flag = true;
        } else if (!std.mem.startsWith(u8, s, "-")) {
            target = s;
        }
    }
    const cid: usize = if (std.mem.eql(u8, target, "self") or
        std.mem.eql(u8, target, "1"))
        common.CID_SELF
    else
        resolveChildTargetCid(target) orelse {
            common.printFmt("Error: Unknown VM '{s}'.\n", .{target});
            return;
        };

    var pol = pkg_policy.loadGuestManifestPolicy(
        allocator,
        client,
        cid,
    ) catch |err| return common.printApiError("Read package policy", err);
    defer pol.deinit(allocator);
    const allow_s = pkg_policy.formatPolicyAllowValue(allocator, &pol) catch
        return;
    defer allocator.free(allow_s);
    const deny_s = pkg_policy.formatCsv(
        allocator,
        pol.deny.items,
        "none",
    ) catch return;
    defer allocator.free(deny_s);

    if (json_flag) {
        const ae = common.escapeJsonAlloc(allocator, allow_s) catch return;
        defer allocator.free(ae);
        const de = common.escapeJsonAlloc(allocator, deny_s) catch return;
        defer allocator.free(de);
        common.printFmt(
            "{{\"cid\":{d},\"allow\":\"{s}\",\"deny\":\"{s}\"}}\n",
            .{ cid, ae, de },
        );
        return;
    }
    common.printFmt("CID {d} allow: {s}\nCID {d} deny : {s}\n", .{
        cid, allow_s, cid, deny_s,
    });
}

fn failExit() void {
    if (!@import("builtin").is_test) std.process.exit(1);
}

fn cmdAllow(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    args: []const [*:0]const u8,
) void {
    if (args.len < 3) {
        common.printStr("Usage: dsx pkg allow <vm|cid> <*|none|pkg1,pkg2>\n");
        return;
    }
    const target = std.mem.span(args[1]);
    const csv = common.trimWhitespace(std.mem.span(args[2]));
    const cid = resolveChildTargetCid(target) orelse {
        common.printFmt("Error: Unknown child VM '{s}'.\n", .{target});
        return failExit();
    };
    if (!pkg_policy.isValidPkgListCsv(csv, true)) {
        common.printFmt("Error: Invalid package list '{s}'.\n", .{csv});
        return failExit();
    }

    var req_allow: std.ArrayList([]const u8) = .empty;
    defer {
        for (req_allow.items) |it| allocator.free(it);
        req_allow.deinit(allocator);
    }
    const req_allow_all = std.mem.eql(u8, csv, "*");
    if (!req_allow_all) {
        pkg_policy.parseCsvIntoList(allocator, csv, &req_allow) catch return;
    }

    var self_pol = pkg_policy.loadGuestManifestPolicy(
        allocator,
        client,
        common.CID_SELF,
    ) catch |err| return common.printApiError("Read own policy", err);
    defer self_pol.deinit(allocator);
    var child_pol = pkg_policy.loadGuestManifestPolicy(
        allocator,
        client,
        cid,
    ) catch |err| return common.printApiError("Read child policy", err);
    defer child_pol.deinit(allocator);

    var filtered_deny: std.ArrayList([]const u8) = .empty;
    defer {
        for (filtered_deny.items) |it| allocator.free(it);
        filtered_deny.deinit(allocator);
    }
    for (child_pol.deny.items) |d| {
        if (!pkg_policy.containsPkg(req_allow.items, d)) {
            const cpy = allocator.dupe(u8, d) catch return;
            filtered_deny.append(allocator, cpy) catch return;
        }
    }
    const eff_deny = pkg_policy.mergeDenyCsv(
        allocator,
        self_pol.deny.items,
        filtered_deny.items,
    ) catch return;
    defer allocator.free(eff_deny);

    var deny_check: std.ArrayList([]const u8) = .empty;
    defer {
        for (deny_check.items) |it| allocator.free(it);
        deny_check.deinit(allocator);
    }
    pkg_policy.parseCsvIntoList(allocator, eff_deny, &deny_check) catch return;

    if (!pkg_policy.isWithinParentCeiling(
        &self_pol,
        req_allow_all,
        req_allow.items,
        deny_check.items,
    )) {
        common.printStr(
            "Error: Requested allow list exceeds parent's own " ++
                "package ceiling.\n",
        );
        return failExit();
    }

    pkg_policy.updateChildPkgHeaders(
        allocator,
        client,
        cid,
        csv,
        eff_deny,
    ) catch |err| {
        common.printApiError("Update child package policy", err);
        return failExit();
    };
    common.printFmt("✓ Child CID {d} package allowlist set to '{s}'.\n", .{
        cid, csv,
    });
}

fn cmdDeny(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    args: []const [*:0]const u8,
) void {
    if (args.len < 3) {
        common.printStr("Usage: dsx pkg deny <vm|cid> <none|pkg1,pkg2>\n");
        return;
    }
    const target = std.mem.span(args[1]);
    const csv = common.trimWhitespace(std.mem.span(args[2]));
    const cid = resolveChildTargetCid(target) orelse {
        common.printFmt("Error: Unknown child VM '{s}'.\n", .{target});
        return failExit();
    };
    if (!pkg_policy.isValidPkgListCsv(csv, false)) {
        common.printFmt("Error: Invalid deny package list '{s}'.\n", .{csv});
        return failExit();
    }

    var self_pol = pkg_policy.loadGuestManifestPolicy(
        allocator,
        client,
        common.CID_SELF,
    ) catch |err| return common.printApiError("Read own policy", err);
    defer self_pol.deinit(allocator);
    var req_deny: std.ArrayList([]const u8) = .empty;
    defer {
        for (req_deny.items) |it| allocator.free(it);
        req_deny.deinit(allocator);
    }
    pkg_policy.parseCsvIntoList(allocator, csv, &req_deny) catch return;

    const merged = pkg_policy.mergeDenyCsv(
        allocator,
        self_pol.deny.items,
        req_deny.items,
    ) catch return;
    defer allocator.free(merged);

    pkg_policy.updateChildPkgHeaders(
        allocator,
        client,
        cid,
        null,
        merged,
    ) catch |err| {
        common.printApiError("Update child deny policy", err);
        return failExit();
    };
    common.printFmt("✓ Child CID {d} package denylist set to '{s}'.\n", .{
        cid, merged,
    });
}

pub fn cmdPkg(client: *api.DiosixClient, args: []const [*:0]const u8) !void {
    if (args.len == 0) return printPkgUsage();
    const allocator = std.heap.page_allocator;
    const sub = std.meta.stringToEnum(
        PkgSubcmd,
        std.mem.span(args[0]),
    ) orelse return printPkgUsage();

    var json_flag = false;
    var port: u16 = sysconfig.DEFAULT_PKG_PORT;
    var daemon = false;
    var branch: []const u8 = sysconfig.DEFAULT_APK_BRANCH;
    var repo: []const u8 = sysconfig.DEFAULT_APK_REPO;
    var arch: []const u8 = "riscv64";

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const s = std.mem.span(args[i]);
        const opt = std.meta.stringToEnum(ServeOption, s) orelse continue;
        switch (opt) {
            .@"--json", .@"-j" => json_flag = true,
            .@"--daemon", .@"-d" => daemon = true,
            .@"--port", .@"-p" => if (i + 1 < args.len) {
                i += 1;
                port = std.fmt.parseInt(
                    u16,
                    std.mem.span(args[i]),
                    10,
                ) catch sysconfig.DEFAULT_PKG_PORT;
            },
            .@"--branch" => if (i + 1 < args.len) {
                i += 1;
                branch = std.mem.span(args[i]);
            },
            .@"--repo" => if (i + 1 < args.len) {
                i += 1;
                repo = std.mem.span(args[i]);
            },
            .@"--arch" => if (i + 1 < args.len) {
                i += 1;
                arch = std.mem.span(args[i]);
            },
        }
    }

    switch (sub) {
        .status => cmdStatus(allocator, client, json_flag),
        .policy => cmdPolicy(allocator, client, args, json_flag),
        .allow => cmdAllow(allocator, client, args),
        .deny => cmdDeny(allocator, client, args),
        .sync => {
            const rp = pkg_server.RepoPath{
                .branch = branch,
                .repo = repo,
                .arch = arch,
                .file = "APKINDEX.tar.gz",
            };
            const p = pkg_server.ensureRepoArtifact(
                allocator,
                client,
                rp,
                true,
                port,
            ) catch |err| {
                common.printApiError("Sync APKINDEX", err);
                return failExit();
            };
            defer allocator.free(p);
            common.printFmt("✓ Synced APKINDEX to {s}\n", .{p});
        },
        .serve => pkg_server.runServer(client, port, daemon) catch |err| {
            common.printApiError("Start APK proxy", err);
            return failExit();
        },
        .help, .@"--help", .@"-h" => printPkgUsage(),
    }
}

test "pkg: submodule declarations compile cleanly" {
    std.testing.refAllDecls(@This());
    _ = policy;
    _ = index;
    _ = server;
}
