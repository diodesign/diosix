// Deterministic Markdown support-matrix generator for Diosix.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("model.zig");

const Layer = model.Layer;
const FeatureManifest = model.FeatureManifest;
const FeatureNode = model.FeatureNode;

fn relLinkFromDir(
    allocator: Allocator,
    from_dir: []const u8,
    target_ref: []const u8,
) ![]u8 {
    if (from_dir.len == 0 or std.mem.eql(u8, from_dir, ".")) {
        return allocator.dupe(u8, target_ref);
    }

    const hash_idx = std.mem.indexOfScalar(u8, target_ref, '#');
    const path_part = if (hash_idx) |i| target_ref[0..i] else target_ref;
    const frag_part = if (hash_idx) |i| target_ref[i..] else "";

    if (path_part.len > from_dir.len and
        std.mem.startsWith(u8, path_part, from_dir) and
        path_part[from_dir.len] == '/')
    {
        return allocator.print(
            "{s}{s}",
            .{ path_part[from_dir.len + 1 ..], frag_part },
        );
    }

    var up_prefix: std.ArrayList(u8) = .empty;
    defer up_prefix.deinit(allocator);
    var seg_it = std.mem.tokenizeScalar(u8, from_dir, '/');
    while (seg_it.next()) |_| {
        try up_prefix.appendSlice(allocator, "../");
    }
    return allocator.print(
        "{s}{s}{s}",
        .{ up_prefix.items, path_part, frag_part },
    );
}

fn appendFileLinks(
    out: *std.ArrayList(u8),
    allocator: Allocator,
    matrix_dir: []const u8,
    files: []const []const u8,
) !void {
    for (files, 0..) |f_path, i| {
        if (i > 0) try out.appendSlice(allocator, ", ");
        const rel = try relLinkFromDir(allocator, matrix_dir, f_path);
        defer allocator.free(rel);
        const base = std.fs.path.basename(f_path);
        const link = try allocator.print("[`{s}`]({s})", .{ base, rel });
        defer allocator.free(link);
        try out.appendSlice(allocator, link);
    }
}

fn appendDocLinks(
    out: *std.ArrayList(u8),
    allocator: Allocator,
    matrix_dir: []const u8,
    docs: []const []const u8,
) !void {
    for (docs, 0..) |doc_ref, i| {
        if (i > 0) try out.appendSlice(allocator, ", ");
        const rel = try relLinkFromDir(allocator, matrix_dir, doc_ref);
        defer allocator.free(rel);
        const path_part = if (std.mem.indexOfScalar(u8, doc_ref, '#')) |h|
            doc_ref[0..h]
        else
            doc_ref;
        const base = std.fs.path.basename(path_part);
        const link = try allocator.print("[`{s}`]({s})", .{ base, rel });
        defer allocator.free(link);
        try out.appendSlice(allocator, link);
    }
}

fn appendActivators(
    out: *std.ArrayList(u8),
    allocator: Allocator,
    callers: []const []const u8,
) !void {
    if (callers.len == 0) {
        try out.appendSlice(allocator, "Root entry");
        return;
    }
    for (callers, 0..) |caller, i| {
        if (i > 0) try out.appendSlice(allocator, ", ");
        const formatted = try allocator.print("`{s}`", .{caller});
        defer allocator.free(formatted);
        try out.appendSlice(allocator, formatted);
    }
}

fn appendSummaryTable(
    out: *std.ArrayList(u8),
    allocator: Allocator,
    manifest: FeatureManifest,
) !void {
    try out.appendSlice(
        allocator,
        "| Layer | Active | Partial | Unintegrated | Files |\n" ++
            "| :--- | ---: | ---: | ---: | ---: |\n",
    );

    var total_active: usize = 0;
    var total_partial: usize = 0;
    var total_unint: usize = 0;
    var all_unique_files: std.StringHashMapUnmanaged(void) = .empty;
    defer all_unique_files.deinit(allocator);

    for (std.enums.values(Layer)) |layer| {
        var c_active: usize = 0;
        var c_partial: usize = 0;
        var c_unint: usize = 0;
        var layer_files: std.StringHashMapUnmanaged(void) = .empty;
        defer layer_files.deinit(allocator);

        for (manifest.features) |node| {
            if (node.layer != layer) continue;
            switch (node.status) {
                .active => c_active += 1,
                .partial => c_partial += 1,
                .unintegrated => c_unint += 1,
            }
            for (node.files) |f| {
                try layer_files.put(allocator, f, {});
                try all_unique_files.put(allocator, f, {});
            }
        }

        total_active += c_active;
        total_partial += c_partial;
        total_unint += c_unint;

        const row = try allocator.print(
            "| {s} | {d} | {d} | {d} | {d} |\n",
            .{
                layer.heading(),
                c_active,
                c_partial,
                c_unint,
                layer_files.count(),
            },
        );
        defer allocator.free(row);
        try out.appendSlice(allocator, row);
    }

    const total_row = try allocator.print(
        "| **Total** | **{d}** | **{d}** | **{d}** | **{d}** |\n",
        .{
            total_active,
            total_partial,
            total_unint,
            all_unique_files.count(),
        },
    );
    defer allocator.free(total_row);
    try out.appendSlice(allocator, total_row);
}

fn appendActiveLayerSection(
    out: *std.ArrayList(u8),
    allocator: Allocator,
    matrix_dir: []const u8,
    layer: Layer,
    features: []const FeatureNode,
) !void {
    var has_live = false;
    for (features) |node| {
        if (node.layer == layer and node.status != .unintegrated) {
            has_live = true;
            break;
        }
    }
    if (!has_live) return;

    const hdr = try allocator.print(
        "\n---\n\n## {s}\n\n" ++
            "| Feature | Status | Activated by | Source files | " ++
            "Documentation |\n" ++
            "| :--- | :--- | :--- | :--- | :--- |\n",
        .{layer.heading()},
    );
    defer allocator.free(hdr);
    try out.appendSlice(allocator, hdr);

    for (features) |node| {
        if (node.layer != layer or node.status == .unintegrated) continue;
        const clean_summary =
            try model.collapseWhitespace(allocator, node.summary);
        defer allocator.free(clean_summary);

        const prefix = try allocator.print(
            "| **{s}** (`{s}`) — {s} | {s} | ",
            .{ node.name, node.id, clean_summary, node.status.label() },
        );
        defer allocator.free(prefix);
        try out.appendSlice(allocator, prefix);

        try appendActivators(out, allocator, node.activated_by);
        try out.appendSlice(allocator, " | ");
        try appendFileLinks(out, allocator, matrix_dir, node.files);
        try out.appendSlice(allocator, " | ");
        try appendDocLinks(out, allocator, matrix_dir, node.docs);
        try out.appendSlice(allocator, " |\n");
    }
}

/// Renders the full `docs/support-matrix.md` Markdown document.
/// Caller owns the returned slice.
pub fn renderSupportMatrix(
    allocator: Allocator,
    manifest: FeatureManifest,
    zon_path: []const u8,
    tool_path: []const u8,
) ![]u8 {
    const matrix_dir = std.fs.path.dirname(manifest.matrix_path) orelse ".";
    const zon_rel = try relLinkFromDir(allocator, matrix_dir, zon_path);
    defer allocator.free(zon_rel);
    const tool_rel = try relLinkFromDir(allocator, matrix_dir, tool_path);
    defer allocator.free(tool_rel);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const intro = try allocator.print(
        \\# Feature and support matrix
        \\
        \\This page maps every tracked source file, boot configuration, and
        \\script in Diosix from the machine-mode (M-mode) assembly reset vector
        \\and build graph to its callers and documentation.
        \\
        \\> [!NOTE]
        \\> Generated from [`{s}`]({s})
        \\> by [`{s}`]({s}).
        \\> Run `./scripts/build.sh features` to regenerate this file after
        \\> changing source files or documentation headings.
        \\
        \\---
        \\
        \\## Summary
        \\
        \\Components across the M-mode hypervisor, shared application binary
        \\interface (ABI), supervisor-mode (S-mode) emulation layer, root
        \\virtual machine (VM), and user-mode (U-mode) tools are grouped into
        \\three status tiers: active, partial, and unintegrated.
        \\
        \\
    , .{
        std.fs.path.basename(zon_path),
        zon_rel,
        std.fs.path.basename(tool_path),
        tool_rel,
    });
    defer allocator.free(intro);
    try out.appendSlice(allocator, intro);

    try appendSummaryTable(&out, allocator, manifest);

    for (std.enums.values(Layer)) |layer| {
        try appendActiveLayerSection(
            &out,
            allocator,
            matrix_dir,
            layer,
            manifest.features,
        );
    }

    var has_unintegrated = false;
    for (manifest.features) |node| {
        if (node.status == .unintegrated) {
            has_unintegrated = true;
            break;
        }
    }

    if (has_unintegrated) {
        try out.appendSlice(
            allocator,
            "\n---\n\n" ++
                "## Unintegrated modules awaiting review\n\n" ++
                "The modules below exist in the repository with unit tests " ++
                "or standalone\n" ++
                "definitions, but have no production call path from " ++
                "the M-mode reset vector or build graph.\n\n" ++
                "| Module | Layer | Source files | Summary |\n" ++
                "| :--- | :--- | :--- | :--- |\n",
        );

        for (manifest.features) |node| {
            if (node.status != .unintegrated) continue;
            const clean_summary =
                try model.collapseWhitespace(allocator, node.summary);
            defer allocator.free(clean_summary);

            const prefix = try allocator.print(
                "| **{s}** (`{s}`) | {s} | ",
                .{ node.name, node.id, node.layer.heading() },
            );
            defer allocator.free(prefix);
            try out.appendSlice(allocator, prefix);

            try appendFileLinks(&out, allocator, matrix_dir, node.files);
            const suffix = try allocator.print(" | {s} |\n", .{clean_summary});
            defer allocator.free(suffix);
            try out.appendSlice(allocator, suffix);
        }
    }

    return out.toOwnedSlice(allocator);
}

test "matrix: renders relative links and summary counts deterministically" {
    std.testing.refAllDecls(@This());
    const gpa = std.testing.allocator;

    const manifest: FeatureManifest = .{
        .roots = &.{"boot-entry"},
        .tracked_dirs = &.{},
        .tracked_files = &.{"hypervisor/main.zig"},
        .matrix_path = "docs/support-matrix.md",
        .checked_docs = &.{"docs/architecture.md"},
        .features = &.{
            .{
                .id = "boot-entry",
                .name = "Boot entry",
                .layer = .m_mode,
                .status = .active,
                .files = &.{"hypervisor/main.zig"},
                .summary = "Boots\nthe hypervisor.",
                .docs = &.{
                    "docs/architecture.md#core",
                    "README.md#quickstart",
                },
            },
            .{
                .id = "unused-tree",
                .name = "Unused tree",
                .layer = .m_mode,
                .status = .unintegrated,
                .files = &.{"hypervisor/core/dsa/rbtree.zig"},
                .summary = "No callers.",
            },
        },
    };

    const md = try renderSupportMatrix(
        gpa,
        manifest,
        "build/features.zon",
        "scripts/features.zig",
    );
    defer gpa.free(md);

    try std.testing.expect(
        std.mem.indexOf(
            u8,
            md,
            "[`main.zig`](../hypervisor/main.zig)",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            md,
            "[`architecture.md`](architecture.md#core)",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            md,
            "[`README.md`](../README.md#quickstart)",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            md,
            "| **Total** | **1** | **0** | **1** | **2** |",
        ) != null,
    );
}
