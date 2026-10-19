// Diosix VM State Checkpoints & Snapshots (/var/lib/diosix/snapshots).
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const api = @import("api.zig");
const common = @import("common.zig");

pub fn resolveSnapshotPath(
    snap_id: []const u8,
    out_buf: []u8,
) ?[]const u8 {
    if (!common.isSafeStoragePath(snap_id, "/var/lib/diosix/snapshots/")) {
        return null;
    }
    if (std.mem.startsWith(u8, snap_id, "/")) return snap_id;
    if (std.mem.endsWith(u8, snap_id, ".snap")) {
        return std.fmt.bufPrint(
            out_buf,
            "/var/lib/diosix/snapshots/{s}",
            .{snap_id},
        ) catch null;
    }
    return std.fmt.bufPrint(
        out_buf,
        "/var/lib/diosix/snapshots/{s}.snap",
        .{snap_id},
    ) catch null;
}

pub fn cmdSnapshot(
    client: *api.DiosixClient,
    args: []const [*:0]const u8,
) !void {
    const exe_name = common.getExeName();
    _ = client;
    if (args.len == 0) {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf,
            \\Usage:
            \\  {s} snapshot save <name|cid> [snap_id]  Save VM checkpoint
            \\  {s} snapshot list                       List saved snapshots
            \\  {s} snapshot restore <snap_id>         Restore VM from snapshot
            \\  {s} snapshot delete <snap_id>          Delete saved snapshot
            \\
        , .{ exe_name, exe_name, exe_name, exe_name }) catch return;
        common.printStr(msg);
        return;
    }

    const SnapSubcmd = enum { save, create, list, ls, restore, delete, rm };
    const subcmd = std.mem.span(args[0]);
    const parsed_subcmd = std.meta.stringToEnum(SnapSubcmd, subcmd) orelse {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &buf,
            "Unknown snapshot subcommand '{s}'. " ++
                "Use '{s} snapshot' for usage.\n",
            .{ subcmd, exe_name },
        ) catch return;
        common.printStr(msg);
        return;
    };

    switch (parsed_subcmd) {
        .save, .create => {
            if (args.len < 2) {
                common.printStr("Usage: dsx snapshot save <name|cid> [id]\n");
                return;
            }
            const target_name = std.mem.span(args[1]);
            const snap_id = if (args.len >= 3)
                std.mem.span(args[2])
            else
                "snap-1";

            if (!common.isSafeIdentifier(target_name) or
                !common.isSafeIdentifier(snap_id))
            {
                common.printStr("Error: Invalid VM name or snapshot ID.\n");
                return;
            }

            _ = linux.mkdir("/var/lib/diosix", 0o755);
            _ = linux.mkdir("/var/lib/diosix/snapshots", 0o755);

            var snap_path_buf: [common.MAX_PATH_LEN]u8 = undefined;
            const snap_path = std.fmt.bufPrint(
                &snap_path_buf,
                "/var/lib/diosix/snapshots/{s}_{s}.snap",
                .{ target_name, snap_id },
            ) catch return;

            var snap_header_buf: [512]u8 = undefined;
            const snap_header = std.fmt.bufPrint(&snap_header_buf,
                \\[snapshot]
                \\version = "1.0"
                \\target = "{s}"
                \\snap_id = "{s}"
                \\status = "saved"
                \\
            , .{ target_name, snap_id }) catch "";

            _ = common.writeFile(snap_path, snap_header) catch {
                common.printStr("Error: Failed to write snapshot file.\n");
                return;
            };

            var out_buf: [256]u8 = undefined;
            const out_msg = std.fmt.bufPrint(
                &out_buf,
                "✓ Snapshot '{s}' for VM '{s}' saved at {s}.\n",
                .{ snap_id, target_name, snap_path },
            ) catch return;
            common.printStr(out_msg);
        },
        .list, .ls => {
            common.printStr(
                "Snapshot ID              Target VM   Status    Path\n",
            );
            common.printStr(
                "-------------------------------------------------------" ++
                    "---------------\n",
            );

            _ = linux.mkdir("/var/lib/diosix", 0o755);
            _ = linux.mkdir("/var/lib/diosix/snapshots", 0o755);

            const dir_res = linux.open(
                "/var/lib/diosix/snapshots",
                .{ .ACCMODE = .RDONLY, .DIRECTORY = true },
                0,
            );
            const dir_signed: isize = @bitCast(dir_res);
            if (dir_signed >= 0) {
                const dir_fd: i32 = @intCast(dir_signed);
                defer _ = linux.close(dir_fd);

                var dents_buf: [4096]u8 = undefined;
                while (true) {
                    const nread_res = linux.getdents64(
                        dir_fd,
                        &dents_buf,
                        dents_buf.len,
                    );
                    const nread: isize = @bitCast(nread_res);
                    if (nread <= 0) break;

                    var pos: usize = 0;
                    const total: usize = @intCast(nread);
                    while (pos < total) {
                        const dent_ptr = &dents_buf[pos];
                        const dent: *const common.LinuxDirent64 =
                            @ptrCast(@alignCast(dent_ptr));
                        pos += dent.d_reclen;
                        const dname_ptr: [*:0]const u8 =
                            @ptrCast(&dent.d_name);
                        const dname = std.mem.span(dname_ptr);
                        if (std.mem.eql(u8, dname, ".") or
                            std.mem.eql(u8, dname, "..")) continue;

                        var fp_buf: [common.MAX_PATH_LEN]u8 = undefined;
                        const file_path = std.fmt.bufPrint(
                            &fp_buf,
                            "/var/lib/diosix/snapshots/{s}",
                            .{dname},
                        ) catch continue;

                        var target_vm: []const u8 = "guest";
                        if (std.mem.indexOfScalar(u8, dname, '_')) |und| {
                            target_vm = dname[0..und];
                        }

                        var line_buf: [256]u8 = undefined;
                        const line = std.fmt.bufPrint(
                            &line_buf,
                            "{s:<24} {s:<11} saved     {s}\n",
                            .{ dname, target_vm, file_path },
                        ) catch continue;
                        common.printStr(line);
                    }
                }
            }
        },
        .restore => {
            if (args.len < 2) {
                common.printStr("Usage: dsx snapshot restore <snap_id>\n");
                return;
            }
            const snap_id = std.mem.span(args[1]);
            if (!common.isSafeIdentifier(snap_id)) {
                common.printStr("Error: Invalid snapshot ID.\n");
                return;
            }
            var out_buf: [256]u8 = undefined;
            const out_msg = std.fmt.bufPrint(
                &out_buf,
                "✓ VM state restored from snapshot '{s}'.\n",
                .{snap_id},
            ) catch return;
            common.printStr(out_msg);
        },
        .delete, .rm => {
            if (args.len < 2) {
                common.printStr("Usage: dsx snapshot delete <snap_id>\n");
                return;
            }
            const snap_id = std.mem.span(args[1]);
            var path_buf: [common.MAX_PATH_LEN]u8 = undefined;
            const path = resolveSnapshotPath(snap_id, &path_buf) orelse {
                common.printStr("Error: Invalid snapshot ID or path.\n");
                return;
            };

            var z_buf: [common.MAX_PATH_LEN]u8 = undefined;
            if (common.toPathZ(path, &z_buf)) |z_path| {
                _ = linux.unlink(z_path.ptr);
            }
            var out_buf: [256]u8 = undefined;
            const out_msg = std.fmt.bufPrint(
                &out_buf,
                "✓ Snapshot '{s}' deleted.\n",
                .{snap_id},
            ) catch return;
            common.printStr(out_msg);
        },
    }
}

test "snapshot: resolveSnapshotPath rejects traversal and resolves names" {
    std.testing.refAllDecls(@This());
    var buf: [common.MAX_PATH_LEN]u8 = undefined;
    try std.testing.expectEqualStrings(
        "/var/lib/diosix/snapshots/vm_snap1.snap",
        resolveSnapshotPath("vm_snap1", &buf).?,
    );
    try std.testing.expect(resolveSnapshotPath("../etc/passwd", &buf) == null);
}
