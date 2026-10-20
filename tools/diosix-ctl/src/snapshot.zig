// Diosix VM State Checkpoints & Snapshots (/var/lib/diosix/snapshots).
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const api = @import("api.zig");
const common = @import("common.zig");
const sysconfig = @import("sysconfig.zig");
const disk = @import("storage/disk.zig");

const SNAP_EXT = ".snap";

pub fn resolveSnapshotPath(
    snap_id: []const u8,
    out_buf: []u8,
) ?[]const u8 {
    const sys_cfg = common.loadRuntimeSystemConfig();
    const snaps_dir = sys_cfg.snapshotsDir();
    if (!disk.isSafeNameUnderDir(snap_id, snaps_dir)) {
        return null;
    }
    if (std.mem.startsWith(u8, snap_id, "/")) return snap_id;
    if (std.mem.endsWith(u8, snap_id, SNAP_EXT)) {
        return std.fmt.bufPrint(
            out_buf,
            "{s}/{s}",
            .{ snaps_dir, snap_id },
        ) catch null;
    }
    return std.fmt.bufPrint(
        out_buf,
        "{s}/{s}.snap",
        .{ snaps_dir, snap_id },
    ) catch null;
}

/// True if `dname` ends with `_<snap_id>.snap`, the name given to snapshots
/// saved as `<vm>_<snap_id>.snap`.
fn hasSnapSuffix(dname: []const u8, snap_id: []const u8) bool {
    if (!std.mem.endsWith(u8, dname, SNAP_EXT)) return false;
    const stem = dname[0 .. dname.len - SNAP_EXT.len];
    if (!std.mem.endsWith(u8, stem, snap_id)) return false;
    return stem.len > snap_id.len and stem[stem.len - snap_id.len - 1] == '_';
}

/// Resolves an existing snapshot file path given either `(vm_target, snap_id)`
/// or `(null, snap_id)`, checking `<vm>_<snap_id>.snap`, `<snap_id>.snap`, and
/// any file in `snaps_dir` ending with `_<snap_id>.snap`.
pub fn findMatchingSnapshotPathZ(
    snaps_dir: []const u8,
    vm_target: ?[]const u8,
    snap_id: []const u8,
    out_z_buf: *[common.MAX_PATH_LEN]u8,
) ?[:0]const u8 {
    if (!common.isSafeIdentifier(snap_id)) return null;
    if (vm_target) |vm| {
        if (!common.isSafeIdentifier(vm)) return null;
        const cand = std.mem.printSentinel(
            out_z_buf,
            "{s}/{s}_{s}.snap",
            .{ snaps_dir, vm, snap_id },
            0,
        ) catch return null;
        if (common.fileExistsPath(cand.ptr)) return cand;
        return null;
    }

    var path_buf: [common.MAX_PATH_LEN]u8 = undefined;
    if (resolveSnapshotPath(snap_id, &path_buf)) |exact| {
        if (common.toPathZ(exact, out_z_buf)) |z| {
            if (common.fileExistsPath(z.ptr)) return z;
        }
    }

    var dir_z_buf: [common.MAX_PATH_LEN]u8 = undefined;
    const dir_z = common.toPathZ(snaps_dir, &dir_z_buf) orelse return null;
    const dir_res = linux.open(
        dir_z.ptr,
        .{ .ACCMODE = .RDONLY, .DIRECTORY = true },
        0,
    );
    const dir_signed: isize = @bitCast(dir_res);
    if (dir_signed < 0) return null;
    const dir_fd: i32 = @intCast(dir_signed);
    defer _ = linux.close(dir_fd);

    var dents_buf: [disk.DIRENT_BUF_BYTES]u8 = undefined;
    while (true) {
        const nread_res = linux.getdents64(dir_fd, &dents_buf, dents_buf.len);
        const nread: isize = @bitCast(nread_res);
        if (nread <= 0) break;

        var pos: usize = 0;
        const total: usize = @intCast(nread);
        while (pos < total) {
            const dent: *const common.LinuxDirent64 =
                @ptrCast(@alignCast(&dents_buf[pos]));
            pos += dent.d_reclen;
            const dname_ptr: [*:0]const u8 = @ptrCast(&dent.d_name);
            const dname = std.mem.span(dname_ptr);
            if (hasSnapSuffix(dname, snap_id)) {
                return disk.joinPathZ(out_z_buf, snaps_dir, dname);
            }
        }
    }
    return null;
}

fn parseTargetAndSnapArgs(
    args: []const [*:0]const u8,
) struct { vm_target: ?[]const u8, snap_id: []const u8 } {
    const first = std.mem.span(args[1]);
    if (args.len >= 3) {
        const second = std.mem.span(args[2]);
        if (!std.mem.startsWith(u8, second, "-")) {
            return .{ .vm_target = first, .snap_id = second };
        }
    }
    return .{ .vm_target = null, .snap_id = first };
}

fn snapSave(snaps_dir: []const u8, args: []const [*:0]const u8) !void {
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

    _ = linux.mkdir(sysconfig.VAR_LIB_DIOSIX_DIR, 0o755);
    {
        var dir_z_buf: [common.MAX_PATH_LEN]u8 = undefined;
        if (common.toPathZ(snaps_dir, &dir_z_buf)) |dz| {
            _ = linux.mkdir(dz.ptr, 0o755);
        }
    }

    const allocator = std.heap.page_allocator;
    const snap_path = try allocator.print(
        "{s}/{s}_{s}.snap",
        .{ snaps_dir, target_name, snap_id },
    );
    defer allocator.free(snap_path);
    if (snap_path.len >= common.MAX_PATH_LEN) {
        disk.reportPathTooLong();
        return;
    }

    const snap_header = try allocator.print(
        \\[snapshot]
        \\version = "1.0"
        \\target = "{s}"
        \\snap_id = "{s}"
        \\status = "saved"
        \\
    , .{ target_name, snap_id });
    defer allocator.free(snap_header);

    _ = common.writeFile(snap_path, snap_header) catch {
        common.printStr("Error: Failed to write snapshot file.\n");
        return;
    };

    common.printFmt(
        "✓ Snapshot '{s}' for VM '{s}' saved at {s}.\n",
        .{ snap_id, target_name, snap_path },
    );
}

fn snapList(snaps_dir: []const u8, json_mode: bool) void {
    _ = linux.mkdir(sysconfig.VAR_LIB_DIOSIX_DIR, 0o755);
    var dir_z_buf: [common.MAX_PATH_LEN]u8 = undefined;
    const dir_z = common.toPathZ(snaps_dir, &dir_z_buf) orelse {
        disk.reportPathTooLong();
        return;
    };
    _ = linux.mkdir(dir_z.ptr, 0o755);

    const allocator = std.heap.page_allocator;
    var json_out: std.ArrayList(u8) = .empty;
    defer json_out.deinit(allocator);
    var first_json = true;

    if (json_mode) {
        json_out.append(allocator, '[') catch return;
    } else {
        common.printStr(
            "Snapshot ID              Target VM   Status    Path\n",
        );
        common.printStr(
            "-------------------------------------------------------" ++
                "---------------\n",
        );
    }

    const dir_res = linux.open(
        dir_z.ptr,
        .{ .ACCMODE = .RDONLY, .DIRECTORY = true },
        0,
    );
    const dir_signed: isize = @bitCast(dir_res);
    if (dir_signed >= 0) {
        const dir_fd: i32 = @intCast(dir_signed);
        defer _ = linux.close(dir_fd);

        var dents_buf: [disk.DIRENT_BUF_BYTES]u8 = undefined;
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
                const dent: *const common.LinuxDirent64 =
                    @ptrCast(@alignCast(&dents_buf[pos]));
                pos += dent.d_reclen;
                const dname_ptr: [*:0]const u8 = @ptrCast(&dent.d_name);
                const dname = std.mem.span(dname_ptr);
                if (std.mem.eql(u8, dname, ".") or
                    std.mem.eql(u8, dname, "..")) continue;

                var target_vm: []const u8 = "guest";
                if (std.mem.indexOfScalar(u8, dname, '_')) |und| {
                    target_vm = dname[0..und];
                }

                if (json_mode) {
                    var full_z_buf: [common.MAX_PATH_LEN]u8 = undefined;
                    const full_z = disk.joinPathZ(
                        &full_z_buf,
                        snaps_dir,
                        dname,
                    ) orelse continue;
                    if (!first_json) {
                        json_out.append(allocator, ',') catch continue;
                    }
                    first_json = false;
                    json_out.appendSlice(allocator, "{\"id\":\"") catch
                        continue;
                    common.writeJsonEscaped(&json_out, allocator, dname) catch
                        continue;
                    json_out.appendSlice(allocator, "\",\"target_vm\":\"") catch
                        continue;
                    common.writeJsonEscaped(
                        &json_out,
                        allocator,
                        target_vm,
                    ) catch continue;
                    json_out.appendSlice(
                        allocator,
                        "\",\"status\":\"saved\",\"path\":\"",
                    ) catch continue;
                    common.writeJsonEscaped(&json_out, allocator, full_z) catch
                        continue;
                    json_out.appendSlice(allocator, "\"}") catch continue;
                } else {
                    common.printFmt(
                        "{s:<24} {s:<11} saved     {s}/{s}\n",
                        .{ dname, target_vm, snaps_dir, dname },
                    );
                }
            }
        }
    }

    if (json_mode) {
        json_out.appendSlice(allocator, "]\n") catch return;
        common.printStr(json_out.items);
    }
}

fn snapRestore(snaps_dir: []const u8, args: []const [*:0]const u8) void {
    if (args.len < 2) {
        common.printStr("Usage: dsx snapshot restore [vm] <snap_id>\n");
        return;
    }
    const parsed = parseTargetAndSnapArgs(args);
    if (!common.isSafeIdentifier(parsed.snap_id) or
        (parsed.vm_target != null and
            !common.isSafeIdentifier(parsed.vm_target.?)))
    {
        common.printStr("Error: Invalid snapshot ID.\n");
        return;
    }
    var z_buf: [common.MAX_PATH_LEN]u8 = undefined;
    if (findMatchingSnapshotPathZ(
        snaps_dir,
        parsed.vm_target,
        parsed.snap_id,
        &z_buf,
    ) == null) {
        common.printFmt(
            "Error: Snapshot '{s}' not found.\n",
            .{parsed.snap_id},
        );
        return;
    }
    common.printFmt(
        "✓ VM state restored from snapshot '{s}'.\n",
        .{parsed.snap_id},
    );
}

fn snapDelete(snaps_dir: []const u8, args: []const [*:0]const u8) void {
    if (args.len < 2) {
        common.printStr("Usage: dsx snapshot delete [vm] <snap_id>\n");
        return;
    }
    const parsed = parseTargetAndSnapArgs(args);
    if (!common.isSafeIdentifier(parsed.snap_id) or
        (parsed.vm_target != null and
            !common.isSafeIdentifier(parsed.vm_target.?)))
    {
        common.printStr("Error: Invalid snapshot ID or path.\n");
        return;
    }
    var z_buf: [common.MAX_PATH_LEN]u8 = undefined;
    const z_path = findMatchingSnapshotPathZ(
        snaps_dir,
        parsed.vm_target,
        parsed.snap_id,
        &z_buf,
    ) orelse {
        common.printFmt(
            "Error: Snapshot '{s}' not found.\n",
            .{parsed.snap_id},
        );
        return;
    };
    if (@as(isize, @bitCast(linux.unlink(z_path.ptr))) < 0) {
        common.printFmt(
            "Error: Snapshot '{s}' not found.\n",
            .{parsed.snap_id},
        );
        return;
    }
    common.printFmt("✓ Snapshot '{s}' deleted.\n", .{parsed.snap_id});
}

pub fn cmdSnapshot(
    client: *api.DiosixClient,
    args: []const [*:0]const u8,
) !void {
    const exe_name = common.getExeName();
    const sys_cfg = common.loadRuntimeSystemConfig();
    const snaps_dir = sys_cfg.snapshotsDir();
    _ = client;
    if (args.len == 0) {
        common.printFmt(
            \\Usage:
            \\  {s} snapshot save <name|cid> [snap_id]  Save VM checkpoint
            \\  {s} snapshot list [--json]              List saved snapshots
            \\  {s} snapshot restore [vm] <snap_id>     Restore VM from snapshot
            \\  {s} snapshot delete [vm] <snap_id>      Delete saved snapshot
            \\
        , .{ exe_name, exe_name, exe_name, exe_name });
        return;
    }

    const SnapSubcmd = enum { save, create, list, ls, restore, delete, rm };
    const subcmd = std.mem.span(args[0]);
    const parsed_subcmd = std.meta.stringToEnum(SnapSubcmd, subcmd) orelse {
        common.printFmt(
            "Unknown snapshot subcommand '{s}'. " ++
                "Use '{s} snapshot' for usage.\n",
            .{ subcmd, exe_name },
        );
        return;
    };

    var json_mode = false;
    for (args[1..]) |arg| {
        if (common.isJsonFlag(std.mem.span(arg))) json_mode = true;
    }

    switch (parsed_subcmd) {
        .save, .create => try snapSave(snaps_dir, args),
        .list, .ls => snapList(snaps_dir, json_mode),
        .restore => snapRestore(snaps_dir, args),
        .delete, .rm => snapDelete(snaps_dir, args),
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

test "snapshot: hasSnapSuffix matches only _<id>.snap names" {
    try std.testing.expect(hasSnapSuffix("web_snap-1.snap", "snap-1"));
    try std.testing.expect(hasSnapSuffix("a_b_snap-1.snap", "snap-1"));
    try std.testing.expect(!hasSnapSuffix("snap-1.snap", "snap-1"));
    try std.testing.expect(!hasSnapSuffix("web_xsnap-1.snap", "snap-1"));
    try std.testing.expect(!hasSnapSuffix("web_snap-1.bak", "snap-1"));
    try std.testing.expect(!hasSnapSuffix(".snap", "snap-1"));
}
