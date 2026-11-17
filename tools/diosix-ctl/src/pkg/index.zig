// Alpine APKINDEX Parser and Transitive Dependency Closure Evaluator.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const policy = @import("policy.zig");

const TAR_BLOCK_BYTES: usize = 512;
const MAX_APKINDEX_BYTES: usize = 32 * 1024 * 1024;
const MAX_BFS_VISITED: usize = 4096;

pub fn isSafeRepoSegment(seg: []const u8) bool {
    if (seg.len == 0 or seg.len > 128) return false;
    if (std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) {
        return false;
    }
    if (std.mem.indexOf(u8, seg, "..") != null) return false;
    for (seg) |c| {
        if (c == '/' or c == '\\' or c <= 0x20 or c >= 0x7f) return false;
    }
    return true;
}

pub fn parseApkFilenamePkgName(filename: []const u8) ?[]const u8 {
    if (!isSafeRepoSegment(filename)) return null;
    if (!std.mem.endsWith(u8, filename, ".apk")) return null;
    const stem = filename[0 .. filename.len - 4];
    const rel_dash = std.mem.lastIndexOfScalar(u8, stem, '-') orelse
        return null;
    const rel = stem[rel_dash + 1 ..];
    if (rel.len < 2 or rel[0] != 'r') return null;
    for (rel[1..]) |c| {
        if (!std.ascii.isDigit(c)) return null;
    }
    const ver_dash = std.mem.lastIndexOfScalar(
        u8,
        stem[0..rel_dash],
        '-',
    ) orelse return null;
    if (ver_dash == 0 or rel_dash <= ver_dash + 1) return null;
    return stem[0..ver_dash];
}

pub fn stripVersionConstraint(tok: []const u8) []const u8 {
    for (tok, 0..) |c, i| {
        if (c == '=' or c == '<' or c == '>' or c == '~') return tok[0..i];
    }
    return tok;
}

fn findApkIndexInTar(allocator: std.mem.Allocator, tar: []const u8) !?[]u8 {
    var off: usize = 0;
    while (off + TAR_BLOCK_BYTES <= tar.len) {
        const hdr = tar[off .. off + TAR_BLOCK_BYTES];
        if (hdr[0] == 0) break;
        const name_end = std.mem.indexOfScalar(u8, hdr[0..100], 0) orelse 100;
        const name = hdr[0..name_end];
        const sz_raw = std.mem.trim(u8, hdr[124..136], " \x00");
        const size = if (sz_raw.len > 0)
            std.fmt.parseInt(usize, sz_raw, 8) catch return null
        else
            0;
        const data_start = off + TAR_BLOCK_BYTES;
        if (size > MAX_APKINDEX_BYTES or data_start + size > tar.len) {
            return null;
        }
        if (std.mem.eql(u8, name, "APKINDEX")) {
            const duped = try allocator.dupe(
                u8,
                tar[data_start .. data_start + size],
            );
            return duped;
        }
        const aligned = std.mem.alignForward(usize, size, TAR_BLOCK_BYTES);
        off = std.math.add(usize, data_start, aligned) catch break;
    }
    return null;
}

pub fn extractApkIndexFromTarGz(
    allocator: std.mem.Allocator,
    compressed: []const u8,
) ![]u8 {
    const win_buf = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(win_buf);

    var in_reader: std.Io.Reader = .fixed(compressed);
    while (in_reader.seek + 18 <= compressed.len) {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var dec = std.compress.flate.Decompress.init(
            &in_reader,
            .gzip,
            win_buf,
        );
        _ = try dec.reader.streamRemaining(&aw.writer);
        if (aw.written().len > MAX_APKINDEX_BYTES) {
            return error.ApkIndexTooLarge;
        }
        if (try findApkIndexInTar(allocator, aw.written())) |found| {
            return found;
        }
    }
    return error.ApkIndexNotFound;
}

pub const ApkGraph = struct {
    raw: []u8,
    deps: std.StringHashMapUnmanaged([]const u8) = .empty,
    provides: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty,

    pub fn deinit(self: *ApkGraph, allocator: std.mem.Allocator) void {
        self.deps.deinit(allocator);
        var it = self.provides.valueIterator();
        while (it.next()) |list| list.deinit(allocator);
        self.provides.deinit(allocator);
        allocator.free(self.raw);
    }

    pub fn parse(
        allocator: std.mem.Allocator,
        index_bytes: []const u8,
    ) !ApkGraph {
        const raw = try allocator.dupe(u8, index_bytes);
        errdefer allocator.free(raw);

        var graph = ApkGraph{ .raw = raw };
        errdefer graph.deinit(allocator);

        var stanzas = std.mem.splitSequence(u8, raw, "\n\n");
        while (stanzas.next()) |stanza| {
            var pkg_opt: ?[]const u8 = null;
            var deps_opt: ?[]const u8 = null;
            var prov_opt: ?[]const u8 = null;

            var lines = std.mem.splitScalar(u8, stanza, '\n');
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, line, "P:")) {
                    pkg_opt = std.mem.trim(u8, line[2..], " \r");
                } else if (std.mem.startsWith(u8, line, "D:")) {
                    deps_opt = std.mem.trim(u8, line[2..], " \r");
                } else if (std.mem.startsWith(u8, line, "p:")) {
                    prov_opt = std.mem.trim(u8, line[2..], " \r");
                }
            }
            const pkg = pkg_opt orelse continue;
            if (pkg.len == 0) continue;
            try graph.deps.put(allocator, pkg, deps_opt orelse "");
            if (prov_opt) |p_line| {
                var tok = std.mem.tokenizeScalar(u8, p_line, ' ');
                while (tok.next()) |raw_p| {
                    const sym = stripVersionConstraint(raw_p);
                    if (sym.len == 0) continue;
                    const gop = try graph.provides.getOrPut(allocator, sym);
                    if (!gop.found_existing) gop.value_ptr.* = .empty;
                    try gop.value_ptr.append(allocator, pkg);
                }
            }
        }
        return graph;
    }
};

fn enqueueIfEligible(
    allocator: std.mem.Allocator,
    visited: *std.StringHashMapUnmanaged(void),
    queue: *std.ArrayList([]const u8),
    deny: []const []const u8,
    pkg: []const u8,
) !void {
    if (pkg.len == 0 or policy.containsPkg(deny, pkg)) return;
    if (visited.count() >= MAX_BFS_VISITED) return;
    const gop = try visited.getOrPut(allocator, pkg);
    if (!gop.found_existing) try queue.append(allocator, pkg);
}

fn allowsPkg(
    allocator: std.mem.Allocator,
    graph_opt: ?*const ApkGraph,
    pol: *const policy.PkgPolicy,
    pkg_name: []const u8,
) !bool {
    if (policy.containsPkg(pol.deny.items, pkg_name)) return false;
    if (pol.allow_all) return true;
    if (policy.containsPkg(pol.allow.items, pkg_name)) return true;
    const graph = graph_opt orelse return false;

    var visited: std.StringHashMapUnmanaged(void) = .empty;
    defer visited.deinit(allocator);
    var queue: std.ArrayList([]const u8) = .empty;
    defer queue.deinit(allocator);

    for (pol.allow.items) |root| {
        try enqueueIfEligible(
            allocator,
            &visited,
            &queue,
            pol.deny.items,
            root,
        );
    }

    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const cur = queue.items[head];
        if (std.mem.eql(u8, cur, pkg_name)) return true;
        const deps_line = graph.deps.get(cur) orelse continue;
        var tok = std.mem.tokenizeScalar(u8, deps_line, ' ');
        while (tok.next()) |raw_dep| {
            if (raw_dep.len == 0 or raw_dep[0] == '!' or raw_dep[0] == '/') {
                continue;
            }
            const dep = stripVersionConstraint(raw_dep);
            if (graph.deps.contains(dep)) {
                try enqueueIfEligible(
                    allocator,
                    &visited,
                    &queue,
                    pol.deny.items,
                    dep,
                );
            }
            if (graph.provides.get(dep)) |providers| {
                for (providers.items) |prov_pkg| {
                    try enqueueIfEligible(
                        allocator,
                        &visited,
                        &queue,
                        pol.deny.items,
                        prov_pkg,
                    );
                }
            }
        }
    }
    return false;
}

pub fn isPackagePermitted(
    allocator: std.mem.Allocator,
    graph_opt: ?*const ApkGraph,
    self_pol: *const policy.PkgPolicy,
    child_pol: *const policy.PkgPolicy,
    pkg_name: []const u8,
) !bool {
    const parent_ok = try allowsPkg(allocator, graph_opt, self_pol, pkg_name);
    if (!parent_ok) return false;
    return allowsPkg(allocator, graph_opt, child_pol, pkg_name);
}

fn writeTarEntryForTest(
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    name: []const u8,
    content: []const u8,
) !void {
    var hdr: [TAR_BLOCK_BYTES]u8 = @splat(0);
    @memcpy(hdr[0..name.len], name);
    _ = try std.fmt.bufPrint(hdr[124..136], "{o:0>11}", .{content.len});
    try out.appendSlice(alloc, &hdr);
    try out.appendSlice(alloc, content);
    const rem = content.len % TAR_BLOCK_BYTES;
    if (rem != 0) try out.appendNTimes(alloc, 0, TAR_BLOCK_BYTES - rem);
}

fn gzipBytesForTest(alloc: std.mem.Allocator, data: []const u8) ![]u8 {
    var aw = try std.Io.Writer.Allocating.initCapacity(alloc, 4096);
    defer aw.deinit();
    var win: [std.compress.flate.max_window_len]u8 = undefined;
    var comp = try std.compress.flate.Compress.init(
        &aw.writer,
        &win,
        .gzip,
        .fastest,
    );
    try comp.writer.writeAll(data);
    try comp.finish();
    return alloc.dupe(u8, aw.written());
}

test "pkg/index: filename parsing, multi-gzip APKINDEX, and dep closure" {
    std.testing.refAllDecls(@This());
    const t = std.testing;
    const alloc = t.allocator;

    try t.expectEqualStrings(
        "chrony-common",
        parseApkFilenamePkgName("chrony-common-4.8-r7.apk").?,
    );
    try t.expectEqualStrings(
        "doas",
        parseApkFilenamePkgName("doas-6.8.2-r8.apk").?,
    );
    try t.expectEqualStrings(
        "musl",
        parseApkFilenamePkgName("musl-1.2.6_git20250101-r0.apk").?,
    );
    try t.expect(parseApkFilenamePkgName("APKINDEX.tar.gz") == null);
    try t.expect(parseApkFilenamePkgName("../evil-1.0-r0.apk") == null);

    const sample_idx =
        "P:chrony\n" ++
        "D:chrony-common=4.8-r7 so:libcap.so.2\n\n" ++
        "P:chrony-common\n" ++
        "D:so:libc.musl-riscv64.so.1\n\n" ++
        "P:libcap2\n" ++
        "p:so:libcap.so.2=2.78\n\n" ++
        "P:doas\n" ++
        "D:/bin/sh so:libc.musl-riscv64.so.1\n";

    var tar0: std.ArrayList(u8) = .empty;
    defer tar0.deinit(alloc);
    try writeTarEntryForTest(&tar0, alloc, ".SIGN.RSA.test.rsa.pub", "sig");
    const gz0 = try gzipBytesForTest(alloc, tar0.items);
    defer alloc.free(gz0);

    var tar1: std.ArrayList(u8) = .empty;
    defer tar1.deinit(alloc);
    try writeTarEntryForTest(&tar1, alloc, "APKINDEX", sample_idx);
    const gz1 = try gzipBytesForTest(alloc, tar1.items);
    defer alloc.free(gz1);

    const multi_gz = try std.mem.concat(alloc, u8, &.{ gz0, gz1 });
    defer alloc.free(multi_gz);

    const extracted = try extractApkIndexFromTarGz(alloc, multi_gz);
    defer alloc.free(extracted);
    try t.expectEqualStrings(sample_idx, extracted);

    var graph = try ApkGraph.parse(alloc, extracted);
    defer graph.deinit(alloc);

    var parent_pol = try policy.parsePolicy(
        alloc,
        "# diosix-pkg-allow: *\n",
    );
    defer parent_pol.deinit(alloc);
    var child_pol = try policy.parsePolicy(
        alloc,
        "# diosix-pkg-allow: chrony\n",
    );
    defer child_pol.deinit(alloc);

    try t.expect(
        try isPackagePermitted(
            alloc,
            &graph,
            &parent_pol,
            &child_pol,
            "chrony",
        ),
    );
    try t.expect(
        try isPackagePermitted(
            alloc,
            &graph,
            &parent_pol,
            &child_pol,
            "chrony-common",
        ),
    );
    try t.expect(
        try isPackagePermitted(
            alloc,
            &graph,
            &parent_pol,
            &child_pol,
            "libcap2",
        ),
    );
    try t.expect(
        !try isPackagePermitted(alloc, &graph, &parent_pol, &child_pol, "doas"),
    );

    var deny_pol = try policy.parsePolicy(
        alloc,
        "# diosix-pkg-deny: libcap2\n",
    );
    defer deny_pol.deinit(alloc);
    try t.expect(
        !try isPackagePermitted(
            alloc,
            &graph,
            &deny_pol,
            &child_pol,
            "libcap2",
        ),
    );
}
