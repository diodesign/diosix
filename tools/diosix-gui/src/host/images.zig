// VM Image Repository Discovery, Storage Enumeration & Guest Creation for GUI.
//
// Scans /var/lib/diosix/images, /usr/share/diosix/images,
// /var/lib/diosix/disks, and /var/lib/diosix/iso to populate the Create VM
// workflow, and launches new guest VMs via `dsx run`.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const label = @import("../label.zig");
const paths = @import("../paths.zig");
const mem_size = @import("mem.zig");
const proc = @import("proc.zig");

pub const MAX_VM_IMAGES: usize = 24;
pub const MAX_STORAGE_OPTIONS: usize = 12;
pub const IMAGE_TITLE_BYTES: usize = 64;
pub const IMAGE_PATH_BYTES: usize = 160;
const DIRENT_BUF_BYTES: usize = 4096;

const LinuxDirent64 = extern struct {
    d_ino: u64 align(1),
    d_off: i64 align(1),
    d_reclen: u16 align(1),
    d_type: u8 align(1),
    d_name: [1]u8 align(1),
};

pub const VmImageEntry = struct {
    title_buf: [IMAGE_TITLE_BYTES]u8 = @splat(0),
    title_len: usize = 0,
    filename_buf: [IMAGE_TITLE_BYTES]u8 = @splat(0),
    filename_len: usize = 0,
    path_buf: [IMAGE_PATH_BYTES]u8 = @splat(0),
    path_len: usize = 0,
    size_bytes: u64 = 0,
    default_vcpus: u32 = 2,
    default_ram_mb: u32 = 256,

    pub fn getTitle(self: *const VmImageEntry) []const u8 {
        return self.title_buf[0..self.title_len];
    }

    pub fn getFilename(self: *const VmImageEntry) []const u8 {
        return self.filename_buf[0..self.filename_len];
    }

    pub fn getPath(self: *const VmImageEntry) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    pub fn setTitle(self: *VmImageEntry, s: []const u8) void {
        const res = label.fmtLabel(&self.title_buf, "{s}", .{s});
        self.title_len = res.len;
    }

    pub fn setFilename(self: *VmImageEntry, s: []const u8) void {
        const res = label.fmtLabel(&self.filename_buf, "{s}", .{s});
        self.filename_len = res.len;
    }

    pub fn setPath(self: *VmImageEntry, s: []const u8) void {
        const res = label.fmtLabel(&self.path_buf, "{s}", .{s});
        self.path_len = res.len;
    }
};

pub const StorageOption = struct {
    label_buf: [IMAGE_TITLE_BYTES]u8 = @splat(0),
    label_len: usize = 0,
    path_buf: [IMAGE_PATH_BYTES]u8 = @splat(0),
    path_len: usize = 0,

    pub fn getLabel(self: *const StorageOption) []const u8 {
        return self.label_buf[0..self.label_len];
    }

    pub fn getPath(self: *const StorageOption) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    pub fn setLabel(self: *StorageOption, s: []const u8) void {
        const res = label.fmtLabel(&self.label_buf, "{s}", .{s});
        self.label_len = res.len;
    }

    pub fn setPath(self: *StorageOption, s: []const u8) void {
        const res = label.fmtLabel(&self.path_buf, "{s}", .{s});
        self.path_len = res.len;
    }
};

pub const CreatedVmRecord = struct {
    name_buf: [IMAGE_TITLE_BYTES]u8 = @splat(0),
    name_len: usize = 0,
    image_buf: [IMAGE_PATH_BYTES]u8 = @splat(0),
    image_len: usize = 0,
    storage_buf: [IMAGE_PATH_BYTES]u8 = @splat(0),
    storage_len: usize = 0,
    vcpus: u32 = 0,
    ram_mb: u32 = 0,
    pcpu_quota_pct: u32 = 20,
    ram_quota_mb: u32 = 0,

    pub fn getName(self: *const CreatedVmRecord) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn getImagePath(self: *const CreatedVmRecord) []const u8 {
        return self.image_buf[0..self.image_len];
    }

    pub fn getStoragePath(self: *const CreatedVmRecord) []const u8 {
        return self.storage_buf[0..self.storage_len];
    }
};

pub var mock_available_images: ?[]const VmImageEntry = null;
pub var mock_available_storage: ?[]const StorageOption = null;
pub var mock_last_created_vm: ?CreatedVmRecord = null;

fn queryFileSizeBytes(path_z: [*:0]const u8) u64 {
    const fd_rc = linux.open(path_z, .{ .ACCMODE = .RDONLY }, 0);
    const signed_fd: isize = @bitCast(fd_rc);
    if (signed_fd < 0) return 0;
    const fd: i32 = @intCast(signed_fd);
    defer _ = linux.close(fd);

    const end_rc = linux.lseek(fd, 0, linux.SEEK.END);
    const signed_end: isize = @bitCast(end_rc);
    if (signed_end <= 0) return 0;
    return @intCast(signed_end);
}

fn isSupportedImageFilename(dname: []const u8) bool {
    if (dname.len == 0 or dname[0] == '.') return false;
    if (std.mem.eql(u8, dname, "default.elf") or
        std.mem.eql(u8, dname, "default.bin"))
    {
        return false;
    }
    return std.mem.endsWith(u8, dname, ".elf") or
        std.mem.endsWith(u8, dname, ".bin") or
        std.mem.endsWith(u8, dname, ".iso");
}

fn scanImagesInDir(
    dir_z: [*:0]const u8,
    out: *[MAX_VM_IMAGES]VmImageEntry,
    count: *usize,
) void {
    const dir_rc = linux.open(
        dir_z,
        .{ .ACCMODE = .RDONLY, .DIRECTORY = true },
        0,
    );
    const signed_dir: isize = @bitCast(dir_rc);
    if (signed_dir < 0) return;
    const dir_fd: i32 = @intCast(signed_dir);
    defer _ = linux.close(dir_fd);

    const dir_slice = std.mem.span(dir_z);
    var dents_buf: [DIRENT_BUF_BYTES]u8 = undefined;
    while (count.* < MAX_VM_IMAGES) {
        const nread_rc = linux.getdents64(
            dir_fd,
            &dents_buf,
            dents_buf.len,
        );
        const nread: isize = @bitCast(nread_rc);
        if (nread <= 0) break;

        var pos: usize = 0;
        const total: usize = @intCast(nread);
        while (pos < total and count.* < MAX_VM_IMAGES) {
            const dent: *const LinuxDirent64 =
                @ptrCast(@alignCast(&dents_buf[pos]));
            pos += dent.d_reclen;
            const dname_ptr: [*:0]const u8 = @ptrCast(&dent.d_name);
            const dname = std.mem.span(dname_ptr);
            if (!isSupportedImageFilename(dname)) continue;

            var dup = false;
            for (0..count.*) |i| {
                if (std.mem.eql(u8, out[i].getFilename(), dname)) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;

            var full_z: [IMAGE_PATH_BYTES]u8 = @splat(0);
            const full_slice = std.fmt.bufPrint(
                full_z[0 .. full_z.len - 1],
                "{s}/{s}",
                .{ dir_slice, dname },
            ) catch continue;
            full_z[full_slice.len] = 0;

            var entry = VmImageEntry{
                .size_bytes = queryFileSizeBytes(@ptrCast(&full_z)),
                .default_vcpus = 2,
                .default_ram_mb = 256,
            };
            entry.setTitle(proc.friendlyImageName(dname));
            entry.setFilename(dname);
            entry.setPath(full_slice);
            out[count.*] = entry;
            count.* += 1;
        }
    }
}

pub fn queryAvailableImages(out: *[MAX_VM_IMAGES]VmImageEntry) usize {
    if (mock_available_images) |mocks| {
        const n = @min(mocks.len, MAX_VM_IMAGES);
        for (0..n) |i| out[i] = mocks[i];
        return n;
    }

    if (builtin.is_test) {
        var base = VmImageEntry{
            .size_bytes = 43 * mem_size.MIB,
            .default_vcpus = 2,
            .default_ram_mb = 256,
        };
        base.setTitle("Diosix Base Linux");
        base.setFilename("diosix-base-linux.elf");
        base.setPath(paths.DEFAULT_BASE_LINUX_IMAGE_PATH);
        out[0] = base;
        return 1;
    }

    var count: usize = 0;
    const dirs = [_][*:0]const u8{
        paths.VAR_IMAGES_DIR,
        paths.VAR_ISO_DIR,
        paths.SHARE_IMAGES_DIR,
    };
    for (dirs) |d| {
        scanImagesInDir(d, out, &count);
    }

    if (count == 0) {
        var fallback = VmImageEntry{
            .size_bytes = 43 * mem_size.MIB,
            .default_vcpus = 2,
            .default_ram_mb = 256,
        };
        fallback.setTitle("Diosix Base Linux");
        fallback.setFilename("diosix-base-linux.elf");
        fallback.setPath(paths.DEFAULT_BASE_LINUX_IMAGE_PATH);
        out[0] = fallback;
        count = 1;
    }
    return count;
}

fn scanStorageInDir(
    dir_z: [*:0]const u8,
    prefix: []const u8,
    out: *[MAX_STORAGE_OPTIONS]StorageOption,
    count: *usize,
) void {
    const dir_rc = linux.open(
        dir_z,
        .{ .ACCMODE = .RDONLY, .DIRECTORY = true },
        0,
    );
    const signed_dir: isize = @bitCast(dir_rc);
    if (signed_dir < 0) return;
    const dir_fd: i32 = @intCast(signed_dir);
    defer _ = linux.close(dir_fd);

    const dir_slice = std.mem.span(dir_z);
    var dents_buf: [DIRENT_BUF_BYTES]u8 = undefined;
    while (count.* < MAX_STORAGE_OPTIONS) {
        const nread_rc = linux.getdents64(
            dir_fd,
            &dents_buf,
            dents_buf.len,
        );
        const nread: isize = @bitCast(nread_rc);
        if (nread <= 0) break;

        var pos: usize = 0;
        const total: usize = @intCast(nread);
        while (pos < total and count.* < MAX_STORAGE_OPTIONS) {
            const dent: *const LinuxDirent64 =
                @ptrCast(@alignCast(&dents_buf[pos]));
            pos += dent.d_reclen;
            const dname_ptr: [*:0]const u8 = @ptrCast(&dent.d_name);
            const dname = std.mem.span(dname_ptr);
            if (dname.len == 0 or dname[0] == '.') continue;
            const valid_ext = std.mem.endsWith(u8, dname, ".img") or
                std.mem.endsWith(u8, dname, ".raw") or
                std.mem.endsWith(u8, dname, ".qcow2") or
                std.mem.endsWith(u8, dname, ".iso");
            if (!valid_ext) continue;

            var full_z: [IMAGE_PATH_BYTES]u8 = @splat(0);
            const full_slice = std.fmt.bufPrint(
                full_z[0 .. full_z.len - 1],
                "{s}/{s}",
                .{ dir_slice, dname },
            ) catch continue;
            full_z[full_slice.len] = 0;

            const sz = queryFileSizeBytes(@ptrCast(&full_z));
            var sz_buf: [mem_size.MEM_SIZE_STR_BYTES]u8 = undefined;
            const sz_str = mem_size.formatMemorySize(&sz_buf, sz);

            var opt = StorageOption{};
            var lbl_buf: [IMAGE_TITLE_BYTES]u8 = undefined;
            opt.setLabel(
                label.fmtLabel(&lbl_buf, "{s}: {s} ({s})", .{
                    prefix,
                    dname,
                    sz_str,
                }),
            );
            opt.setPath(full_slice);
            out[count.*] = opt;
            count.* += 1;
        }
    }
}

pub fn queryAvailableStorageOptions(
    out: *[MAX_STORAGE_OPTIONS]StorageOption,
) usize {
    if (mock_available_storage) |mocks| {
        const n = @min(mocks.len, MAX_STORAGE_OPTIONS);
        for (0..n) |i| out[i] = mocks[i];
        return n;
    }

    var none_opt = StorageOption{};
    none_opt.setLabel("None");
    none_opt.setPath("");
    out[0] = none_opt;
    var count: usize = 1;

    if (builtin.is_test) {
        var disk_opt = StorageOption{};
        disk_opt.setLabel("disk: data-vol.img (1 GB)");
        disk_opt.setPath("/var/lib/diosix/disks/data-vol.img");
        out[1] = disk_opt;
        return 2;
    }

    scanStorageInDir(paths.VAR_DISKS_DIR, "disk", out, &count);
    scanStorageInDir(paths.VAR_ISO_DIR, "iso", out, &count);
    return count;
}

pub fn recordCreatedVm(
    image_path: []const u8,
    vcpus: u32,
    ram_mb: u32,
    storage_path: []const u8,
) void {
    recordCreatedVmWithQuota(
        "",
        image_path,
        vcpus,
        ram_mb,
        20,
        ram_mb,
        storage_path,
    );
}

pub fn recordCreatedVmWithQuota(
    vm_name: []const u8,
    image_path: []const u8,
    vcpus: u32,
    ram_mb: u32,
    pcpu_quota_pct: u32,
    ram_quota_mb: u32,
    storage_path: []const u8,
) void {
    var rec = CreatedVmRecord{
        .vcpus = vcpus,
        .ram_mb = ram_mb,
        .pcpu_quota_pct = pcpu_quota_pct,
        .ram_quota_mb = ram_quota_mb,
    };
    const nm_s = label.fmtLabel(&rec.name_buf, "{s}", .{vm_name});
    rec.name_len = nm_s.len;
    const img_s = label.fmtLabel(&rec.image_buf, "{s}", .{image_path});
    rec.image_len = img_s.len;
    const st_s = label.fmtLabel(&rec.storage_buf, "{s}", .{storage_path});
    rec.storage_len = st_s.len;
    mock_last_created_vm = rec;
}

pub fn resolveDsxBinarySlice() []const u8 {
    for (paths.DSX_BIN_PATHS) |dsx_bin| {
        const st_fd = linux.open(dsx_bin, .{ .ACCMODE = .RDONLY }, 0);
        if (@as(isize, @bitCast(st_fd)) >= 0) {
            _ = linux.close(@intCast(@as(isize, @bitCast(st_fd))));
            return std.mem.span(dsx_bin);
        }
    }
    return std.mem.span(paths.DSX_BIN_PATHS[0]);
}

pub fn createGuestVm(
    image_path: []const u8,
    vcpus: u32,
    ram_mb: u32,
    storage_path: []const u8,
) bool {
    if (image_path.len == 0) return false;
    recordCreatedVm(image_path, vcpus, ram_mb, storage_path);
    if (builtin.is_test or mock_available_images != null) {
        return true;
    }

    var img_z: [IMAGE_PATH_BYTES]u8 = @splat(0);
    _ = std.fmt.bufPrint(img_z[0 .. img_z.len - 1], "{s}", .{image_path}) catch
        return false;
    var vcpu_z: [16]u8 = @splat(0);
    _ = std.fmt.bufPrint(vcpu_z[0..15], "{d}", .{@max(1, vcpus)}) catch
        return false;
    var ram_z: [24]u8 = @splat(0);
    _ = std.fmt.bufPrint(ram_z[0..23], "{d}M", .{@max(64, ram_mb)}) catch
        return false;
    var st_z: [IMAGE_PATH_BYTES]u8 = @splat(0);
    if (storage_path.len > 0) {
        const dst = st_z[0 .. st_z.len - 1];
        _ = std.fmt.bufPrint(dst, "{s}", .{storage_path}) catch return false;
    }

    const is_iso = std.mem.endsWith(u8, storage_path, ".iso");
    const st_flag: [*:0]const u8 = if (is_iso) "--cdrom" else "--disk";

    for (paths.DSX_BIN_PATHS) |dsx_bin| {
        const st_fd = linux.open(dsx_bin, .{ .ACCMODE = .RDONLY }, 0);
        if (@as(isize, @bitCast(st_fd)) < 0) continue;
        _ = linux.close(@intCast(@as(isize, @bitCast(st_fd))));

        const pid_rc = linux.fork();
        const signed_pid: isize = @bitCast(pid_rc);
        if (signed_pid < 0) return false;
        if (signed_pid == 0) {
            const img_arg: [*:0]const u8 = @ptrCast(&img_z);
            const vcpu_arg: [*:0]const u8 = @ptrCast(&vcpu_z);
            const ram_arg: [*:0]const u8 = @ptrCast(&ram_z);
            const st_arg: ?[*:0]const u8 = if (storage_path.len > 0)
                @ptrCast(&st_z)
            else
                null;
            var argv = [_:null]?[*:0]const u8{
                dsx_bin,
                "run",
                img_arg,
                "--vcpus",
                vcpu_arg,
                "--ram",
                ram_arg,
                if (st_arg != null) st_flag else null,
                st_arg,
                null,
            };
            var envp = [_:null]?[*:0]const u8{null};
            _ = linux.execve(dsx_bin, &argv, &envp);
            linux.exit(127);
        }
        var status: u32 = 0;
        _ = linux.waitpid(@intCast(signed_pid), @ptrCast(&status), 0);
        return (status & 0xff00) == 0;
    }
    return false;
}

test "images: queryAvailableImages and createGuestVm" {
    std.testing.refAllDecls(@This());
    defer mock_available_images = null;
    defer mock_available_storage = null;
    defer mock_last_created_vm = null;
    var imgs: [MAX_VM_IMAGES]VmImageEntry = undefined;
    const count = queryAvailableImages(&imgs);
    try std.testing.expect(count >= 1);
    const expectStr = std.testing.expectEqualStrings;
    try expectStr("Diosix Base Linux", imgs[0].getTitle());
    try std.testing.expect(
        createGuestVm(imgs[0].getPath(), 2, 512, "/var/lib/diosix/disks/d.img"),
    );
    try std.testing.expectEqual(@as(u32, 2), mock_last_created_vm.?.vcpus);
    try std.testing.expectEqual(@as(u32, 512), mock_last_created_vm.?.ram_mb);
}
