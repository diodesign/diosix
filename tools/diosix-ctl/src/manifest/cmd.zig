// Diosix Hypervisor Guest Management CLI — Manifest & Service Resolution CLI.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const api = @import("../api.zig");
const manifest = @import("../manifest.zig");
const common = @import("../common.zig");
const sysconfig = @import("../sysconfig.zig");

const CID_PARENT = common.CID_PARENT;
const CID_SELF = common.CID_SELF;
const CID_FIRST_CHILD = common.CID_FIRST_CHILD;
const MAX_MANIFEST_SIZE = common.MAX_MANIFEST_SIZE;
const printStr = common.printStr;
const printFmt = common.printFmt;
const parseCid = common.parseCid;
const printApiError = common.printApiError;
const readBinaryFile = common.readBinaryFile;
const unmapBinaryFile = common.unmapBinaryFile;
const writeFile = common.writeFile;

const ManifestSubcommand = enum { show, validate, prune, set, resolve, route };
const ManifestShowOption = enum {
    @"--file",
    @"-f",
    @"--hypervisor",
    @"--hv",
    @"--cid",
    @"-c",
};
const ManifestPruneOption = enum {
    @"--domain",
    @"-d",
    @"-o",
    @"--out",
    @"--cid",
    @"-c",
    @"--parent",
    @"-p",
};
const ManifestResolveOption = enum { @"--manifest", @"-m" };

fn readLocalManifest(sys_path: []const u8) ?[]u8 {
    return readBinaryFile(
        sysconfig.DEFAULT_LOCAL_MANIFEST_PATH,
        MAX_MANIFEST_SIZE,
    ) catch readBinaryFile(sys_path, MAX_MANIFEST_SIZE) catch null;
}

fn printErr(prefix: []const u8, err: anyerror) void {
    printStr(prefix);
    printStr(@errorName(err));
    printStr("\n");
}

fn printManifestText(content: []const u8) void {
    printStr(content);
    if (content.len > 0 and content[content.len - 1] != '\n') {
        printStr("\n");
    }
}

/// Prints the manifest the hypervisor holds for `target_cid`. Returns false
/// when the hypervisor has no manifest attached to that VM.
fn printHvManifest(client: *api.DiosixClient, target_cid: usize) !bool {
    const allocator = std.heap.page_allocator;
    const m_buf = try allocator.alloc(u8, MAX_MANIFEST_SIZE);
    defer allocator.free(m_buf);
    const actual_len = try client.getManifest(target_cid, m_buf);
    if (actual_len == 0) return false;
    printManifestText(m_buf[0..@min(actual_len, m_buf.len)]);
    return true;
}

pub fn cmdManifest(
    client: *api.DiosixClient,
    args: []const [*:0]const u8,
) !void {
    const exe_name = common.getExeName();
    if (args.len == 0) {
        printFmt(
            \\Usage: {s} manifest <subcmd> [options]
            \\  show [--file <path>] [--hv]    Display active or file manifest
            \\  validate <file.toml>           Validate manifest syntax
            \\  prune <sys.toml> --domain <d>  Attenuate manifest for child VM
            \\  resolve <service_alias>        Resolve service route
            \\  set <cid> <file.toml>          Stage manifest for child VM
            \\
        , .{exe_name});
        return;
    }
    const subcmd = std.mem.span(args[0]);
    const allocator = std.heap.page_allocator;

    const cmd = std.meta.stringToEnum(ManifestSubcommand, subcmd) orelse {
        printFmt(
            "Unknown manifest subcommand '{s}'. " ++
                "Available: show, validate, prune, resolve, set\n",
            .{subcmd},
        );
        return;
    };

    switch (cmd) {
        .show => cmdManifestShow(client, exe_name, args),
        .validate => {
            if (args.len < 2) {
                printFmt(
                    "Usage: {s} manifest validate <path/to/manifest.toml>\n",
                    .{exe_name},
                );
                return;
            }
            const fp = std.mem.span(args[1]);
            const content = readBinaryFile(fp, MAX_MANIFEST_SIZE) catch |err| {
                printErr("Failed to read manifest file: ", err);
                return;
            };
            defer unmapBinaryFile(content);

            const is_sys = std.mem.indexOf(u8, content, "[system]") != null or
                std.mem.indexOf(u8, content, "[domains.") != null or
                std.mem.indexOf(u8, content, "[subtrees.") != null;
            if (is_sys) {
                const parse_fn = manifest.parseSystemManifest;
                var sys = parse_fn(allocator, content) catch |err| {
                    printErr("System manifest parse error: ", err);
                    return;
                };
                defer sys.deinit();
                manifest.validateSystemManifest(&sys) catch |err| {
                    printErr("System manifest validation failed: ", err);
                    return;
                };
                printStr("✓ System manifest is valid.\n");
            } else {
                const parse_fn = manifest.parseChildManifest;
                var child = parse_fn(allocator, content) catch |err| {
                    printErr("Child manifest parse error: ", err);
                    return;
                };
                defer child.deinit();
                manifest.validateChildManifest(&child) catch |err| {
                    printErr("Child manifest validation failed: ", err);
                    return;
                };
                printStr("✓ Child VM manifest is valid.\n");
            }
        },
        .prune => cmdManifestPrune(allocator, exe_name, args),
        .set => {
            if (args.len < 3) {
                printFmt(
                    "Usage: {s} manifest set <target_cid> <manifest.toml>\n",
                    .{exe_name},
                );
                return;
            }
            const target_cid = parseCid(std.mem.span(args[1])) catch {
                printStr("Error: Invalid target CID\n");
                return;
            };
            if (target_cid == CID_PARENT or target_cid == 0) {
                printStr(
                    "Error: Cannot stage manifest for parent VM (CID 0).\n",
                );
                return;
            }
            const fp = std.mem.span(args[2]);
            const content = readBinaryFile(fp, MAX_MANIFEST_SIZE) catch |err| {
                printErr("Failed to read manifest file: ", err);
                return;
            };
            defer unmapBinaryFile(content);

            client.setManifest(target_cid, content) catch |err| {
                printApiError("Set manifest", err);
                return;
            };
            printFmt(
                "✓ Manifest successfully staged in hypervisor for CID {d}\n",
                .{target_cid},
            );
        },
        .resolve, .route => {
            if (args.len < 2) {
                printFmt(
                    "Usage: {s} manifest resolve <service_alias> " ++
                        "[--manifest <file.toml>]\n",
                    .{exe_name},
                );
                return;
            }
            const service_name = std.mem.span(args[1]);
            var m_path: ?[]const u8 = null;
            for (args[2..], 2..) |arg, i| {
                const span = std.mem.span(arg);
                const is_opt =
                    std.meta.stringToEnum(ManifestResolveOption, span) != null;
                if (is_opt and args.len > i + 1) {
                    m_path = std.mem.span(args[i + 1]);
                }
            }
            try cmdResolve(client, service_name, m_path);
        },
    }
}

fn cmdManifestShow(
    client: *api.DiosixClient,
    exe_name: []const u8,
    args: []const [*:0]const u8,
) void {
    const sys_cfg = common.loadRuntimeSystemConfig();
    var file_path: ?[]const u8 = null;
    var use_hv: bool = false;
    var target_cid: usize = CID_SELF;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const span = std.mem.span(args[i]);
        if (std.meta.stringToEnum(ManifestShowOption, span)) |opt| {
            switch (opt) {
                .@"--file", .@"-f" => {
                    if (i + 1 >= args.len) {
                        printStr("Error: '--file' requires a file path.\n");
                        return;
                    }
                    i += 1;
                    file_path = std.mem.span(args[i]);
                },
                .@"--hypervisor", .@"--hv" => use_hv = true,
                .@"--cid", .@"-c" => {
                    if (i + 1 >= args.len) {
                        printStr("Error: '--cid' requires a CID value.\n");
                        return;
                    }
                    i += 1;
                    target_cid = parseCid(std.mem.span(args[i])) catch CID_SELF;
                },
            }
        } else if (std.mem.startsWith(u8, span, "-")) {
            printFmt(
                "Error: Unknown option '{s}'. Usage: {s} manifest show " ++
                    "[--file <path>] [--hv] [--cid <cid>]\n",
                .{ span, exe_name },
            );
            return;
        }
    }

    if (file_path) |fp| {
        const content = readBinaryFile(fp, MAX_MANIFEST_SIZE) catch |err| {
            printErr("Failed to read manifest file: ", err);
            return;
        };
        defer unmapBinaryFile(content);
        printManifestText(content);
    } else if (use_hv) {
        const printed = printHvManifest(client, target_cid) catch |err| {
            printApiError("Get hypervisor manifest", err);
            return;
        };
        if (!printed) {
            printStr("# (No manifest attached to this VM in hypervisor)\n");
        }
    } else if (readLocalManifest(sys_cfg.systemManifestPath())) |content| {
        defer unmapBinaryFile(content);
        printManifestText(content);
    } else {
        if (printHvManifest(client, target_cid)) |printed| {
            if (printed) return;
        } else |_| {}
        printStr(
            "No manifest found at /etc/diosix/manifest.toml " ++
                "or in hypervisor.\n",
        );
    }
}

fn cmdManifestPrune(
    allocator: std.mem.Allocator,
    exe_name: []const u8,
    args: []const [*:0]const u8,
) void {
    if (args.len < 2) {
        printFmt(
            "Usage: {s} manifest prune <system.toml> --domain <name> " ++
                "[-o <out.toml>] [--cid <cid>]\n",
            .{exe_name},
        );
        return;
    }
    const sys_path = std.mem.span(args[1]);
    var domain_name: ?[]const u8 = null;
    var out_file: ?[]const u8 = null;
    var child_cid: usize = CID_FIRST_CHILD;
    var parent_cid: usize = CID_SELF;

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const span = std.mem.span(args[i]);
        if (std.meta.stringToEnum(ManifestPruneOption, span)) |opt| {
            if (i + 1 >= args.len) {
                printStr("Error: Option requires a value.\n");
                return;
            }
            i += 1;
            const val = std.mem.span(args[i]);
            switch (opt) {
                .@"--domain", .@"-d" => domain_name = val,
                .@"-o", .@"--out" => out_file = val,
                .@"--cid", .@"-c" => {
                    child_cid = parseCid(val) catch CID_FIRST_CHILD;
                },
                .@"--parent", .@"-p" => {
                    parent_cid = parseCid(val) catch CID_SELF;
                },
            }
        } else if (std.mem.startsWith(u8, span, "-")) {
            printFmt(
                "Error: Unknown option '{s}'. Usage: {s} manifest prune " ++
                    "<sys.toml> --domain <name> [-o <out.toml>] [--cid <c>]\n",
                .{ span, exe_name },
            );
            return;
        }
    }

    const dom = domain_name orelse {
        printStr("Error: --domain <name> is required for prune.\n");
        return;
    };

    const content = readBinaryFile(sys_path, MAX_MANIFEST_SIZE) catch |err| {
        printErr("Failed to read system manifest: ", err);
        return;
    };
    defer unmapBinaryFile(content);

    var sys = manifest.parseSystemManifest(allocator, content) catch |err| {
        printErr("Failed to parse system manifest: ", err);
        return;
    };
    defer sys.deinit();

    var child = manifest.pruneSystemManifest(
        allocator,
        &sys,
        dom,
        child_cid,
        parent_cid,
        null,
    ) catch |err| {
        printErr("Failed to prune manifest: ", err);
        return;
    };
    defer child.deinit();
    const ser_fn = manifest.serializeChildManifest;
    const serialized = ser_fn(allocator, &child) catch |err| {
        printErr("Failed to serialize attenuated manifest: ", err);
        return;
    };
    defer allocator.free(serialized);
    if (out_file) |out_path| {
        writeFile(out_path, serialized) catch |err| {
            printErr("Failed to write output manifest: ", err);
            return;
        };
        printFmt("✓ Attenuated manifest written to {s}\n", .{out_path});
    } else {
        printStr(serialized);
    }
}

pub fn cmdResolve(
    client: *api.DiosixClient,
    service_alias: []const u8,
    manifest_path: ?[]const u8,
) !void {
    const sys_cfg = common.loadRuntimeSystemConfig();
    const allocator = std.heap.page_allocator;
    var content_slice: ?[]u8 = null;
    var is_allocated: bool = false;
    defer if (content_slice) |cs| {
        if (is_allocated) allocator.free(cs) else unmapBinaryFile(cs);
    };

    if (manifest_path) |mp| {
        content_slice = readBinaryFile(mp, MAX_MANIFEST_SIZE) catch null;
    } else if (readLocalManifest(sys_cfg.systemManifestPath())) |c| {
        content_slice = c;
    } else {
        const m_buf = try allocator.alloc(u8, MAX_MANIFEST_SIZE);
        defer allocator.free(m_buf);
        if (client.getManifest(CID_SELF, m_buf)) |actual_len| {
            const safe_len = @min(actual_len, m_buf.len);
            if (safe_len > 0) {
                content_slice = try allocator.dupe(u8, m_buf[0..safe_len]);
                is_allocated = true;
            }
        } else |_| {}
    }

    const cs = content_slice orelse {
        printStr("Error: No manifest found to resolve service against.\n");
        return;
    };

    var child = manifest.parseChildManifest(allocator, cs) catch |err| {
        printErr("Error parsing manifest: ", err);
        return;
    };
    defer child.deinit();

    if (manifest.resolveService(&child, service_alias)) |req| {
        printFmt(
            "Service resolution:\n  Service : {s}\n  Alias   : {s}\n" ++
                "  CID     : {d}\n",
            .{ req.service, req.as_alias, req.target_cid },
        );
        if (req.target_domain.len > 0) {
            printFmt("  Domain  : {s}\n", .{req.target_domain});
        }
        printFmt(
            "  Channel : {s}\n  Mode    : {s}\n",
            .{ req.channel, req.mode },
        );
    } else {
        printFmt(
            "Error: Service '{s}' not found in current VM manifest.\n",
            .{service_alias},
        );
    }
}

test "manifest/cmd: subcommand and option enums match CLI flags" {
    std.testing.refAllDecls(@This());
    try std.testing.expectEqual(
        ManifestSubcommand.prune,
        std.meta.stringToEnum(ManifestSubcommand, "prune").?,
    );
    try std.testing.expectEqual(
        ManifestShowOption.@"--hv",
        std.meta.stringToEnum(ManifestShowOption, "--hv").?,
    );
}
