// Graph reachability, 1:1 file coverage, and doc-anchor verifier.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("model.zig");

const FeatureManifest = model.FeatureManifest;
const DocHeading = model.DocHeading;

const MAX_TEXT_FILE_BYTES: u64 = 64 * 1024 * 1024;

pub fn readTextFileAllocSentinel(
    dir: std.Io.Dir,
    io: std.Io,
    allocator: Allocator,
    sub_path: []const u8,
) ![:0]u8 {
    var file = try dir.openFile(io, sub_path, .{});
    defer file.close(io);
    const st = try file.stat(io);
    if (st.size > MAX_TEXT_FILE_BYTES) return error.FileTooLarge;
    const size: usize = @intCast(st.size);
    const buf = try allocator.allocSentinel(u8, size, 0);
    errdefer allocator.free(buf);
    var reader = file.reader(io, &.{});
    const n = reader.interface.readSliceShort(buf) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
    };
    if (n != size) return error.ShortRead;
    return buf;
}

fn lessThanStrings(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

/// Pure verification over an in-memory set of existing repository files and
/// parsed Markdown heading tables. Returns allocated error strings in `arena`.
pub fn verifyModel(
    arena: Allocator,
    manifest: FeatureManifest,
    repo_files: *const std.StringHashMapUnmanaged(void),
    doc_headings: *const std.StringHashMapUnmanaged([]const DocHeading),
) ![][]const u8 {
    var errors: std.ArrayList([]const u8) = .empty;

    var node_by_id: std.StringHashMapUnmanaged(usize) = .empty;
    for (manifest.features, 0..) |node, idx| {
        const trimmed_id = std.mem.trim(u8, node.id, " \t\r\n");
        if (trimmed_id.len == 0) {
            try errors.append(
                arena,
                try arena.print("feature[{d}] has an empty id", .{idx}),
            );
            continue;
        }
        if (node_by_id.contains(node.id)) {
            try errors.append(
                arena,
                try arena.print("duplicate feature id '{s}'", .{node.id}),
            );
            continue;
        }
        try node_by_id.put(arena, node.id, idx);

        if (node.files.len == 0) {
            try errors.append(
                arena,
                try arena.print("feature '{s}' lists zero files", .{node.id}),
            );
        }
        if (std.mem.trim(u8, node.summary, " \t\r\n").len == 0) {
            try errors.append(
                arena,
                try arena.print("feature '{s}' has empty summary", .{node.id}),
            );
        }

        switch (node.status) {
            .unintegrated => {
                if (node.activated_by.len != 0) {
                    try errors.append(
                        arena,
                        try arena.print(
                            "unintegrated feature '{s}' cannot have " ++
                                "activated_by callers",
                            .{node.id},
                        ),
                    );
                }
                if (node.docs.len != 0) {
                    try errors.append(
                        arena,
                        try arena.print(
                            "unintegrated feature '{s}' must not claim docs",
                            .{node.id},
                        ),
                    );
                }
            },
            .active, .partial => {
                if (node.docs.len == 0) {
                    try errors.append(
                        arena,
                        try arena.print(
                            "feature '{s}' requires at least one doc link",
                            .{node.id},
                        ),
                    );
                }
            },
        }
    }

    const n_nodes = manifest.features.len;
    var rev_edges = try arena.alloc(std.ArrayList(usize), n_nodes);
    for (0..n_nodes) |i| rev_edges[i] = .empty;

    for (manifest.features, 0..) |node, idx| {
        for (node.activated_by) |caller_id| {
            const caller_idx = node_by_id.get(caller_id) orelse {
                try errors.append(
                    arena,
                    try arena.print(
                        "feature '{s}' references unknown caller '{s}'",
                        .{ node.id, caller_id },
                    ),
                );
                continue;
            };
            if (caller_idx == idx) {
                try errors.append(
                    arena,
                    try arena.print(
                        "feature '{s}' cannot activate itself",
                        .{node.id},
                    ),
                );
                continue;
            }
            if (manifest.features[caller_idx].status == .unintegrated) {
                try errors.append(
                    arena,
                    try arena.print(
                        "feature '{s}' cannot be activated by unintegrated " ++
                            "'{s}'",
                        .{ node.id, caller_id },
                    ),
                );
                continue;
            }
            try rev_edges[caller_idx].append(arena, idx);
        }
    }

    var reachable = try arena.alloc(bool, n_nodes);
    @memset(reachable, false);
    var queue: std.ArrayList(usize) = .empty;

    for (manifest.roots) |root_id| {
        const r_idx = node_by_id.get(root_id) orelse {
            try errors.append(
                arena,
                try arena.print("missing root feature '{s}'", .{root_id}),
            );
            continue;
        };
        const r_node = manifest.features[r_idx];
        if (r_node.status == .unintegrated) {
            try errors.append(
                arena,
                try arena.print(
                    "root feature '{s}' cannot be unintegrated",
                    .{root_id},
                ),
            );
        }
        if (r_node.activated_by.len != 0) {
            try errors.append(
                arena,
                try arena.print(
                    "root feature '{s}' must have empty activated_by",
                    .{root_id},
                ),
            );
        }
        if (!reachable[r_idx]) {
            reachable[r_idx] = true;
            try queue.append(arena, r_idx);
        }
    }

    var q_head: usize = 0;
    while (q_head < queue.items.len) : (q_head += 1) {
        const cur = queue.items[q_head];
        for (rev_edges[cur].items) |child_idx| {
            if (!reachable[child_idx]) {
                reachable[child_idx] = true;
                try queue.append(arena, child_idx);
            }
        }
    }

    for (manifest.features, 0..) |node, idx| {
        if (node.status != .unintegrated and !reachable[idx]) {
            try errors.append(
                arena,
                try arena.print(
                    "feature '{s}' is not reachable from roots",
                    .{node.id},
                ),
            );
        }
    }

    var claimed_by: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (manifest.features) |node| {
        var seen_in_node: std.StringHashMapUnmanaged(void) = .empty;
        for (node.files) |f_path| {
            if (seen_in_node.contains(f_path)) {
                try errors.append(
                    arena,
                    try arena.print(
                        "duplicate file '{s}' inside feature '{s}'",
                        .{ f_path, node.id },
                    ),
                );
                continue;
            }
            try seen_in_node.put(arena, f_path, {});

            if (claimed_by.get(f_path)) |prev_owner| {
                try errors.append(
                    arena,
                    try arena.print(
                        "file '{s}' is claimed by both '{s}' and '{s}'",
                        .{ f_path, prev_owner, node.id },
                    ),
                );
            } else if (!repo_files.contains(f_path)) {
                try errors.append(
                    arena,
                    try arena.print(
                        "missing file '{s}' claimed by '{s}'",
                        .{ f_path, node.id },
                    ),
                );
            } else {
                try claimed_by.put(arena, f_path, node.id);
            }
        }
    }

    var unclaimed: std.ArrayList([]const u8) = .empty;
    var repo_it = repo_files.keyIterator();
    while (repo_it.next()) |k_ptr| {
        if (!claimed_by.contains(k_ptr.*)) {
            try unclaimed.append(arena, k_ptr.*);
        }
    }
    std.mem.sort([]const u8, unclaimed.items, {}, lessThanStrings);
    for (unclaimed.items) |u_path| {
        try errors.append(
            arena,
            try arena.print(
                "untracked file '{s}' is missing from features.zon",
                .{u_path},
            ),
        );
    }

    var backed_h2: std.StringHashMapUnmanaged(void) = .empty;
    for (manifest.features) |node| {
        if (node.status == .unintegrated) continue;
        for (node.docs) |doc_ref| {
            const hash_idx = std.mem.indexOfScalar(u8, doc_ref, '#');
            const doc_path = if (hash_idx) |i| doc_ref[0..i] else doc_ref;
            const anchor_opt =
                if (hash_idx) |i| doc_ref[i + 1 ..] else null;

            const headings = doc_headings.get(doc_path) orelse {
                try errors.append(
                    arena,
                    try arena.print(
                        "missing doc file '{s}' referenced by '{s}'",
                        .{ doc_path, node.id },
                    ),
                );
                continue;
            };

            if (anchor_opt) |anchor| {
                var matched: ?DocHeading = null;
                for (headings) |h| {
                    if (std.mem.eql(u8, h.slug, anchor)) {
                        matched = h;
                        break;
                    }
                }
                const found = matched orelse {
                    try errors.append(
                        arena,
                        try arena.print(
                            "broken doc anchor '{s}' in feature '{s}'",
                            .{ doc_ref, node.id },
                        ),
                    );
                    continue;
                };
                if (found.parent_h2_slug) |h2| {
                    const sec_key =
                        try arena.print("{s}#{s}", .{ doc_path, h2 });
                    try backed_h2.put(arena, sec_key, {});
                }
            } else {
                for (headings) |h| {
                    if (h.level == 2) {
                        const sec_key = try arena.print(
                            "{s}#{s}",
                            .{ doc_path, h.slug },
                        );
                        try backed_h2.put(arena, sec_key, {});
                    }
                }
            }
        }
    }

    var meta_set: std.StringHashMapUnmanaged(void) = .empty;
    for (manifest.meta_doc_sections) |meta_ref| {
        try meta_set.put(arena, meta_ref, {});
    }

    for (manifest.checked_docs) |c_doc| {
        const headings = doc_headings.get(c_doc) orelse {
            try errors.append(
                arena,
                try arena.print("missing checked_doc '{s}'", .{c_doc}),
            );
            continue;
        };
        for (headings) |h| {
            if (h.level != 2) continue;
            const sec_key = try arena.print("{s}#{s}", .{ c_doc, h.slug });
            if (!backed_h2.contains(sec_key) and !meta_set.contains(sec_key)) {
                try errors.append(
                    arena,
                    try arena.print(
                        "unbacked doc section '{s}' has no active feature",
                        .{sec_key},
                    ),
                );
            }
        }
    }

    return errors.toOwnedSlice(arena);
}

fn loadDocIfMissing(
    dir: std.Io.Dir,
    io: std.Io,
    arena: Allocator,
    doc_headings: *std.StringHashMapUnmanaged([]const DocHeading),
    doc_path: []const u8,
) !void {
    if (doc_headings.contains(doc_path)) return;
    const raw = readTextFileAllocSentinel(dir, io, arena, doc_path) catch |e| {
        switch (e) {
            error.FileNotFound => return,
            else => return e,
        }
    };
    const parsed = try model.parseMarkdownHeadings(arena, raw);
    try doc_headings.put(arena, try arena.dupe(u8, doc_path), parsed);
}

/// Walks the repository workspace, parses all referenced documentation, and
/// validates `manifest`. Prints diagnostics and returns an error on drift.
pub fn verifyWorkspace(
    gpa: Allocator,
    arena: Allocator,
    dir: std.Io.Dir,
    io: std.Io,
    manifest: FeatureManifest,
) !void {
    var repo_files: std.StringHashMapUnmanaged(void) = .empty;

    for (manifest.tracked_files) |tf| {
        if (dir.statFile(io, tf, .{})) |_| {
            try repo_files.put(arena, try arena.dupe(u8, tf), {});
        } else |_| {}
    }

    for (manifest.tracked_dirs) |td| {
        var sub_dir = try dir.openDir(io, td, .{ .iterate = true });
        defer sub_dir.close(io);

        var walker = try sub_dir.walk(gpa);
        defer walker.deinit();

        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            const rel = try arena.print("{s}/{s}", .{ td, entry.path });
            try repo_files.put(arena, rel, {});
        }
    }

    for (manifest.features) |node| {
        for (node.files) |f_path| {
            if (!repo_files.contains(f_path)) {
                if (dir.statFile(io, f_path, .{})) |_| {
                    try repo_files.put(arena, try arena.dupe(u8, f_path), {});
                } else |_| {}
            }
        }
    }

    var doc_headings: std.StringHashMapUnmanaged([]const DocHeading) = .empty;
    for (manifest.checked_docs) |c_doc| {
        try loadDocIfMissing(dir, io, arena, &doc_headings, c_doc);
    }
    for (manifest.features) |node| {
        for (node.docs) |doc_ref| {
            const doc_path = if (std.mem.indexOfScalar(u8, doc_ref, '#')) |i|
                doc_ref[0..i]
            else
                doc_ref;
            try loadDocIfMissing(dir, io, arena, &doc_headings, doc_path);
        }
    }

    const errs = try verifyModel(arena, manifest, &repo_files, &doc_headings);
    if (errs.len > 0) {
        for (errs) |msg| {
            std.debug.print("features.zon error: {s}\n", .{msg});
        }
        return error.FeatureGraphInvalid;
    }
}

test "verify: catches unreachable nodes, untracked files, and unbacked docs" {
    std.testing.refAllDecls(@This());
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var repo_files: std.StringHashMapUnmanaged(void) = .empty;
    try repo_files.put(arena, "entry.s", {});
    try repo_files.put(arena, "orphan.zig", {});
    try repo_files.put(arena, "extra_untracked.zig", {});

    var doc_headings: std.StringHashMapUnmanaged([]const DocHeading) = .empty;
    const h = try model.parseMarkdownHeadings(
        arena,
        "# Doc\n## Boot\n## Ghost feature\n",
    );
    try doc_headings.put(arena, "docs/arch.md", h);

    const manifest: FeatureManifest = .{
        .roots = &.{"boot-entry"},
        .tracked_dirs = &.{},
        .tracked_files = &.{"entry.s"},
        .matrix_path = "docs/support-matrix.md",
        .checked_docs = &.{"docs/arch.md"},
        .features = &.{
            .{
                .id = "boot-entry",
                .name = "Boot",
                .layer = .m_mode,
                .status = .active,
                .files = &.{"entry.s"},
                .summary = "Boot entry.",
                .docs = &.{"docs/arch.md#boot"},
            },
            .{
                .id = "unreachable-active",
                .name = "Orphan",
                .layer = .m_mode,
                .status = .active,
                .files = &.{"orphan.zig"},
                .summary = "Not wired.",
                .docs = &.{"docs/arch.md#missing-anchor"},
            },
        },
    };

    const errs = try verifyModel(arena, manifest, &repo_files, &doc_headings);
    try std.testing.expectEqual(@as(usize, 4), errs.len);
}
